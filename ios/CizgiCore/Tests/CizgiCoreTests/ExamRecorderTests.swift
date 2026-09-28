import XCTest
import SwiftData
@testable import CizgiCore

/// The Çıkmış writes (plan §7.5–7.6), against an in-memory store: which card's
/// FES moves, when a gap opens and closes — and that no answer ever reaches a
/// card's schedule (docs/ADR-012).
final class ExamRecorderTests: XCTestCase {
    private var context: ModelContext!
    private var recorder: ExamRecorder!
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)
    private let question = ExamBankFixture.question("TUS-2019-1-T-050", answer: 2, osymSubject: "Farmakoloji")

    override func setUpWithError() throws {
        let container = try ModelContainer(
            for: Card.self, KnowledgeUnit.self, ReviewLog.self, ExamRun.self, ExamAttempt.self, ExamQuestionState.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
        recorder = ExamRecorder(context: context)
    }

    private func makeCard() -> Card {
        let card = Card(type: .directRecall, front: "Atropin?", back: "Muskarinik antagonist", status: .active)
        context.insert(card)
        return card
    }

    private func makeRun() -> ExamRun {
        let run = ExamRun(mode: .practice, queuedQuestionIds: [question.id])
        context.insert(run)
        return run
    }

    func testACorrectAnswerAsksNothingAndCounts() throws {
        let attempt = recorder.recordAnswer(to: question, selectedOption: 2, in: makeRun(), responseTimeMs: 40_000, at: t0)
        try context.save()
        XCTAssertEqual(attempt.result, .correct)
        XCTAssertEqual(attempt.bridgeOutcome, .notAsked)
        let state = try XCTUnwrap(recorder.existingState(for: question.id))
        XCTAssertEqual(state.attemptCount, 1)
        XCTAssertEqual(state.lastResult, .correct)
    }

    func testAMissLeavesTheBridgePendingAndBlankIsAMiss() {
        let wrong = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        XCTAssertNil(wrong.bridgeOutcome)
        XCTAssertEqual(wrong.isCorrect, false)
        let blank = recorder.recordAnswer(to: question, selectedOption: nil, in: nil, responseTimeMs: 1, at: t0 + 1)
        XCTAssertNil(blank.bridgeOutcome)
        XCTAssertEqual(blank.result, .blank)
        XCTAssertEqual(recorder.state(for: question.id).wrongCount, 2)
    }

    func testAKeylessQuestionIsUnscoredAndNeverBridged() {
        let keyless = ExamBankFixture.question("TUS-2007-1-T-001", answer: nil, status: .keyless)
        let attempt = recorder.recordAnswer(to: keyless, selectedOption: 3, in: nil, responseTimeMs: 1, at: t0)
        XCTAssertEqual(attempt.result, .unscored)
        XCTAssertEqual(attempt.bridgeOutcome, .notAsked)
    }

    func testLinkingWritesFesOncePerRunAndNeverTheSchedule() throws {
        let card = makeCard()
        let due = card.dueDate
        let run = makeRun()
        let first = recorder.recordAnswer(to: question, selectedOption: 0, in: run, responseTimeMs: 1, at: t0)
        XCTAssertTrue(recorder.link(card, to: first, answering: question, at: t0))
        XCTAssertFalse(recorder.link(card, to: first, answering: question, at: t0), "the same tap twice is one link")
        XCTAssertEqual(card.fesScore, 2)
        XCTAssertEqual(card.fesNegativeCount, 1)

        let other = ExamBankFixture.question("TUS-2019-1-T-051", answer: 1)
        let second = recorder.recordAnswer(to: other, selectedOption: 0, in: run, responseTimeMs: 1, at: t0 + 5)
        XCTAssertFalse(recorder.link(card, to: second, answering: other, at: t0 + 5), "one run, one FES write per card")
        XCTAssertEqual(card.fesScore, 2)

        let nextRun = makeRun()
        let third = recorder.recordAnswer(to: question, selectedOption: 0, in: nextRun, responseTimeMs: 1, at: t0 + 10)
        XCTAssertTrue(recorder.link(card, to: third, answering: question, at: t0 + 10))
        XCTAssertEqual(card.fesScore, 4)

        // docs/ADR-012 decision 6: never EarlyPractice, never ReviewLog.
        XCTAssertEqual(card.dueDate, due)
        XCTAssertEqual(card.reviewCount, 0)
        XCTAssertEqual(card.lapseCount, 0)
        XCTAssertEqual(card.softLapseCount, 0)
        try context.save()
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ReviewLog>()), 0)
        XCTAssertEqual(recorder.state(for: question.id).linkedCards, [card.id])
    }

    /// Codex, PR #51 P1: linking A then B on one answer used to overwrite A,
    /// so a later miss of the same run wrote A's FES a second time.
    func testASecondCardOnOneAnswerDoesNotForgetTheFirst() {
        let a = makeCard()
        let b = makeCard()
        let run = makeRun()
        let first = recorder.recordAnswer(to: question, selectedOption: 0, in: run, responseTimeMs: 1, at: t0)
        XCTAssertTrue(recorder.link(a, to: first, answering: question, at: t0))
        XCTAssertTrue(recorder.link(b, to: first, answering: question, at: t0 + 1), "another card that also answers it gets its own FES")
        XCTAssertFalse(recorder.link(a, to: first, answering: question, at: t0 + 2), "back to A on the same answer: still one write")

        let other = ExamBankFixture.question("TUS-2019-1-T-051", answer: 1)
        let second = recorder.recordAnswer(to: other, selectedOption: 0, in: run, responseTimeMs: 1, at: t0 + 5)
        XCTAssertFalse(recorder.link(a, to: second, answering: other, at: t0 + 5), "one run, one FES write per card")
        XCTAssertFalse(recorder.link(b, to: second, answering: other, at: t0 + 6))
        XCTAssertEqual(a.fesScore, 2)
        XCTAssertEqual(a.fesNegativeCount, 1)
        XCTAssertEqual(b.fesScore, 2)
        XCTAssertEqual(first.linkedCardId, a.id, "the latest link is what the attempt shows")
    }

    /// Codex, PR #51: a blank keyless question showed the bridge, and a card
    /// picked there got FES `.wrong` for a question nobody can mark.
    func testAKeylessBlankIsNotAMissAndLinksNothing() throws {
        let keyless = ExamBankFixture.question("TUS-2007-2-K-003", answer: nil, status: .keyless, osymSubject: "Dahiliye")
        let bank = try ExamBank(document: ExamBankFixture.document(questions: [keyless, question]))
        XCTAssertFalse(bank.isMiss(questionId: keyless.id, selectedOption: nil))
        XCTAssertTrue(bank.isMiss(questionId: question.id, selectedOption: nil), "a blank keyed question still is")

        let card = makeCard()
        let attempt = recorder.recordAnswer(to: keyless, selectedOption: nil, in: makeRun(), responseTimeMs: 1, at: t0)
        XCTAssertEqual(attempt.bridgeOutcome, .notAsked)
        XCTAssertFalse(recorder.link(card, to: attempt, answering: keyless, at: t0))
        XCTAssertEqual(card.fesScore, 0)
        XCTAssertNil(attempt.linkedCardId)
    }

    /// Codex, PR #51: a key corrected by a bank update turns a right answer
    /// into a miss; the bridge it now shows must be able to link.
    func testAMissUnderACorrectedKeyCanBeLinked() {
        let card = makeCard()
        let attempt = recorder.recordAnswer(to: question, selectedOption: 2, in: makeRun(), responseTimeMs: 1, at: t0)
        XCTAssertEqual(attempt.bridgeOutcome, .notAsked, "right under the key it was answered with")
        XCTAssertFalse(recorder.link(card, to: attempt, answering: question, at: t0))
        let corrected = ExamBankFixture.question(question.id, answer: 4, osymSubject: "Farmakoloji")
        XCTAssertTrue(recorder.link(card, to: attempt, answering: corrected, at: t0 + 1))
        XCTAssertEqual(card.fesScore, 2)
        XCTAssertEqual(attempt.bridgeOutcome, .linked)
    }

    func testNoCardOpensAGapAndLinkingLaterClosesIt() {
        let attempt = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        recorder.markNoCard(attempt, at: t0)
        XCTAssertEqual(attempt.bridgeOutcome, .noCard)
        XCTAssertEqual(recorder.state(for: question.id).gap.status, .open)

        let card = makeCard()
        let again = recorder.recordAnswer(to: question, selectedOption: 1, in: nil, responseTimeMs: 1, at: t0 + 100)
        recorder.link(card, to: again, answering: question, at: t0 + 100)
        let gap = recorder.state(for: question.id).gap
        XCTAssertEqual(gap.status, .closed)
        XCTAssertEqual(gap.closedByCardId, card.id)
    }

    func testSkippingNeverOverwritesAChoice() {
        let attempt = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        recorder.markNoCard(attempt, at: t0)
        recorder.skipBridge(attempt)
        XCTAssertEqual(attempt.bridgeOutcome, .noCard)
        let pending = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0 + 1)
        recorder.skipBridge(pending)
        XCTAssertEqual(pending.bridgeOutcome, .skipped)
    }

    func testClosingFromTheGapListAndDismissing() {
        let attempt = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        recorder.markNoCard(attempt, at: t0)
        let card = makeCard()
        recorder.closeGap(questionId: question.id, with: card.id, at: t0 + 50)
        XCTAssertEqual(recorder.state(for: question.id).gap.status, .closed)
        XCTAssertEqual(card.fesScore, 0, "closing a gap is not a miss")

        let other = ExamBankFixture.question("TUS-2019-1-T-051", answer: 1)
        let missed = recorder.recordAnswer(to: other, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        recorder.markNoCard(missed, at: t0)
        recorder.dismissGap(questionId: other.id)
        XCTAssertEqual(recorder.state(for: other.id).gap.status, .dismissed)
    }

    func testReconcileReopensGapsOfDeletedCardsAndPrunesLinks() {
        let attempt = recorder.recordAnswer(to: question, selectedOption: 0, in: nil, responseTimeMs: 1, at: t0)
        recorder.markNoCard(attempt, at: t0)
        let gone = UUID()
        recorder.closeGap(questionId: question.id, with: gone, at: t0 + 1)
        XCTAssertEqual(recorder.reconcile(existingCardIds: []), 1)
        let state = recorder.state(for: question.id)
        XCTAssertEqual(state.gap.status, .open)
        XCTAssertEqual(state.linkedCardIds, [])
        XCTAssertEqual(recorder.reconcile(existingCardIds: []), 0, "idempotent")
    }

    func testReportsAreKeptPerQuestion() {
        recorder.report(.key, questionId: question.id)
        XCTAssertEqual(recorder.state(for: question.id).reportedIssue, .key)
        recorder.report(nil, questionId: question.id)
        XCTAssertNil(recorder.state(for: question.id).reportedIssue)
    }
}
