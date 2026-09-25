import Foundation
import SwiftData

/// Every write the Çıkmış screens make, in one place (plan §7.5, §7.6).
///
/// The rules here are the ones most costly to get wrong and least visible on
/// a screen — which card's FES moves, when a gap opens or closes — so they
/// live in CizgiCore beside the models and are tested against an in-memory
/// store, not left inside SwiftUI bodies. None of these methods saves: every
/// caller saves the context it acted in, as `FesScore.record` does.
///
/// What is deliberately *not* here: `EarlyPractice` and `ReviewLog`. A past
/// question never moves a card's schedule (docs/ADR-012 decision 6).
public struct ExamRecorder {
    public let context: ModelContext

    public init(context: ModelContext) {
        self.context = context
    }

    // MARK: State

    public func existingState(for questionId: String) -> ExamQuestionState? {
        var descriptor = FetchDescriptor<ExamQuestionState>(predicate: #Predicate { $0.questionId == questionId })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// The question's state row, created on first use.
    public func state(for questionId: String) -> ExamQuestionState {
        if let existing = existingState(for: questionId) { return existing }
        let state = ExamQuestionState(questionId: questionId)
        context.insert(state)
        return state
    }

    /// A run's answer to one question, fetched rather than read off
    /// `run.attempts` (see `ExamQuestionScreen` for why that list can lag).
    public func attempt(for questionId: String, in run: ExamRun) -> ExamAttempt? {
        let runId = run.id
        let descriptor = FetchDescriptor<ExamAttempt>(predicate: #Predicate { $0.questionId == questionId })
        return ((try? context.fetch(descriptor)) ?? []).first { $0.run?.id == runId }
    }

    // MARK: Answering

    /// Records one answer. A miss on a scoreable question leaves the bridge
    /// pending (`bridgeOutcome == nil`) — the screen asks, and whatever the
    /// owner does next settles it. Everything else is `notAsked`.
    @discardableResult
    public func recordAnswer(
        to question: ExamQuestion,
        selectedOption: Int?,
        in run: ExamRun?,
        responseTimeMs: Int,
        at now: Date
    ) -> ExamAttempt {
        let key = question.isScoreable ? question.answer : nil
        let result = ExamResult.of(selectedOption: selectedOption, answer: key)
        let attempt = ExamAttempt(
            questionId: question.id,
            selectedOption: selectedOption,
            isCorrect: result == .correct ? true : (result == .wrong ? false : nil),
            responseTimeMs: max(0, responseTimeMs),
            answeredAt: now,
            bridgeOutcome: result.isMiss && question.isScoreable ? nil : .notAsked
        )
        attempt.run = run
        context.insert(attempt)
        state(for: question.id).record(result, at: now)
        return attempt
    }

    // MARK: Bridge

    /// "Bu kart karşılıyor". Links the card, closes an open gap with it, and
    /// writes FES `.wrong` to it — once per run: a second miss in the same
    /// sitting that points at the same card is the same evidence, and writing
    /// it twice would double-count one gap in the owner's knowledge.
    ///
    /// Returns whether FES was written.
    @discardableResult
    public func link(_ card: Card, to attempt: ExamAttempt, at now: Date) -> Bool {
        // Fetched, not read off `run.attempts`: that list is filled through
        // its inverse and was seen lagging on screen (ExamQuestionScreen).
        let target: UUID? = card.id
        let runId = attempt.run?.id
        let linkedBefore = (try? context.fetch(
            FetchDescriptor<ExamAttempt>(predicate: #Predicate { $0.linkedCardId == target })
        )) ?? []
        let alreadyWritten = runId != nil && linkedBefore.contains { $0.id != attempt.id && $0.run?.id == runId }
        // Tapping the same card twice on one attempt is one link.
        let sameAttempt = attempt.linkedCardId == card.id && attempt.bridgeOutcome == .linked

        attempt.linkedCardId = card.id
        attempt.bridgeOutcome = .linked
        let state = state(for: attempt.questionId)
        state.link(card.id)
        state.gap = ExamGapLedger.closing(state.gap, byCard: card.id, at: now)

        guard !alreadyWritten, !sameAttempt else { return false }
        FesScore.record(.wrong, on: card, at: now)
        return true
    }

    /// "Hiçbiri — destemde yok": the question goes on "Kitaba dönünce".
    public func markNoCard(_ attempt: ExamAttempt, at now: Date) {
        attempt.bridgeOutcome = .noCard
        let state = state(for: attempt.questionId)
        state.gap = ExamGapLedger.opening(state.gap, at: now)
    }

    /// "Atla", or moving on without answering the bridge. Never overwrites a
    /// choice already made.
    public func skipBridge(_ attempt: ExamAttempt) {
        if attempt.bridgeOutcome == nil { attempt.bridgeOutcome = .skipped }
    }

    // MARK: Gaps

    /// "Kart ekledim" from the gap list, or a confirmed "muhtemelen kapandı".
    /// Links the card too, so the next miss offers it first. No FES: the card
    /// is the answer to the gap, not a card the owner failed.
    public func closeGap(questionId: String, with cardId: UUID, at now: Date) {
        let state = state(for: questionId)
        state.link(cardId)
        state.gap = ExamGapLedger.closing(state.gap, byCard: cardId, at: now)
    }

    public func dismissGap(questionId: String) {
        guard let state = existingState(for: questionId) else { return }
        state.gap = ExamGapLedger.dismissing(state.gap)
    }

    /// Reopens every gap whose closing card is gone, and drops links to cards
    /// that no longer exist. Returns how many gaps reopened.
    @discardableResult
    public func reconcile(existingCardIds: Set<UUID>) -> Int {
        let states = (try? context.fetch(FetchDescriptor<ExamQuestionState>())) ?? []
        var reopened = 0
        for state in states {
            let gap = ExamGapLedger.reconciled(state.gap, existingCardIds: existingCardIds)
            if gap != state.gap {
                state.gap = gap
                reopened += 1
            }
            let live = state.linkedCardIds.filter { UUID(uuidString: $0).map(existingCardIds.contains) ?? false }
            if live != state.linkedCardIds { state.linkedCardIds = live }
        }
        return reopened
    }

    // MARK: Mock (plan §7.4 e)

    /// The run's row for a question, created blank on first touch. A mock
    /// keeps one row per question and rewrites it until the paper is handed
    /// in — an answer there is a mark on the sheet, not a decision yet.
    public func mockAttempt(for question: ExamQuestion, in run: ExamRun, at now: Date) -> ExamAttempt {
        if let existing = attempt(for: question.id, in: run) { return existing }
        let attempt = ExamAttempt(
            questionId: question.id,
            selectedOption: nil,
            isCorrect: nil,
            responseTimeMs: 0,
            answeredAt: now
        )
        attempt.run = run
        context.insert(attempt)
        return attempt
    }

    /// Marks, changes or clears (`nil`) a mock answer. Nothing reaches the
    /// question's state until `submitMock` — the owner may still change it.
    public func setMockAnswer(_ option: Int?, to question: ExamQuestion, in run: ExamRun, at now: Date) {
        let attempt = mockAttempt(for: question, in: run, at: now)
        attempt.selectedOption = option
        let result = ExamResult.of(selectedOption: option, answer: question.isScoreable ? question.answer : nil)
        attempt.isCorrect = result == .correct ? true : (result == .wrong ? false : nil)
        attempt.answeredAt = now
    }

    /// Time spent looking at a question, added on every visit. Creates the
    /// row, so a question seen and left empty is a blank the owner met — not
    /// one the clock never let them reach.
    public func addMockTime(_ milliseconds: Int, to question: ExamQuestion, in run: ExamRun, at now: Date) {
        guard milliseconds > 0 else { return }
        mockAttempt(for: question, in: run, at: now).responseTimeMs += milliseconds
    }

    public func toggleFlag(_ questionId: String, in run: ExamRun) {
        if run.flaggedQuestionIds.contains(questionId) {
            run.flaggedQuestionIds.removeAll { $0 == questionId }
        } else {
            run.flaggedQuestionIds.append(questionId)
        }
    }

    /// Hands the paper in. Every question the owner met becomes history now,
    /// at once, exactly as Pratik records one answer: a miss leaves its
    /// bridge pending for the result screen's review (the bridge is never
    /// asked during a mock), everything else is `notAsked`. Questions the
    /// clock never reached get no row and no history — they are blanks in the
    /// net (`mockScoredAnswers`), not evidence about the question.
    ///
    /// Idempotent: a second call on a finished run does nothing.
    @discardableResult
    public func submitMock(_ run: ExamRun, bank: ExamBank, at now: Date, byTimeLimit: Bool) -> Int {
        guard run.finishedAt == nil else { return 0 }
        let runId = run.id
        let attempts = (try? context.fetch(
            FetchDescriptor<ExamAttempt>(predicate: #Predicate { $0.run?.id == runId })
        )) ?? []
        var recorded = 0
        for attempt in attempts {
            guard let question = bank.question(attempt.questionId) else { continue }
            // Against the bank being handed in to, whatever was stored when
            // the mark was made.
            let result = bank.result(questionId: question.id, selectedOption: attempt.selectedOption)
            attempt.isCorrect = result == .correct ? true : (result == .wrong ? false : nil)
            attempt.bridgeOutcome = result.isMiss && question.isScoreable ? nil : .notAsked
            state(for: question.id).record(result, at: now)
            recorded += 1
        }
        run.clock = run.clock.resuming(at: now)
        run.finishedAt = now
        run.position = run.queuedQuestionIds.count
        run.endedByTimeLimit = byTimeLimit
        return recorded
    }

    // MARK: Reports

    /// "Soruda hata bildir". `nil` withdraws the report.
    public func report(_ issue: ExamReportedIssue?, questionId: String) {
        state(for: questionId).reportedIssue = issue
    }
}
