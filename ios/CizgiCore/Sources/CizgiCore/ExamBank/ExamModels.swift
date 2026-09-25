import Foundation
import SwiftData

// The owner's side of the past exam bank (plan §7.3, docs/ADR-012).
//
// The bank itself is a file; these three models are everything the owner
// does with it, keyed by the stable question id. None of them has a
// relationship to `Card` — a linked card is a plain id — so removing the
// feature is one revert and one migration, and a card deleted from the deck
// cannot cascade into exam history (or the other way round).
//
// Every stored property has a declaration-time default. These are new
// entities, so today's migration does not need them; the next field added to
// any of them will, and `ModelRun.attempt` is the record of what happens when
// one is missing (the store will not open).

public enum ExamRunMode: String, Codable, CaseIterable, Sendable {
    case practice
    /// Faz A3.
    case mock
    case wrongOnly
    case gaps
}

public enum ExamBridgeOutcome: String, Codable, CaseIterable, Sendable {
    /// The owner named the card that should have answered it.
    case linked
    /// "Hiçbiri — destemde yok": a gap was opened.
    case noCard
    case skipped
    /// Answered correctly, or not scoreable: the bridge was not offered.
    case notAsked
}

/// What the owner says is wrong with a question ("Soruda hata bildir").
public enum ExamReportedIssue: String, Codable, CaseIterable, Sendable {
    case stem
    case options
    case key
    case figure
}

@Model
public final class ExamRun {
    @Attribute(.unique) public var id: UUID = UUID()
    public var modeRaw: String = ExamRunMode.practice.rawValue
    /// The single paper of a mock (Faz A3).
    public var paperId: String?
    public var filterJSON: String?
    /// The queue, in order — durable so a relaunch resumes the same run.
    public var queuedQuestionIds: [String] = []
    public var position: Int = 0
    public var flaggedQuestionIds: [String] = []
    public var timeLimitSeconds: Int?
    public var startedAt: Date = Date.now
    public var finishedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \ExamAttempt.run)
    public var attempts: [ExamAttempt] = []

    public var mode: ExamRunMode {
        get { ExamRunMode(rawValue: modeRaw) ?? .practice }
        set { modeRaw = newValue.rawValue }
    }

    public var filter: ExamFilter {
        get { ExamFilter.fromStorage(filterJSON) }
        set { filterJSON = newValue.storageValue }
    }

    public init(
        id: UUID = UUID(),
        mode: ExamRunMode,
        queuedQuestionIds: [String],
        filter: ExamFilter? = nil,
        paperId: String? = nil,
        timeLimitSeconds: Int? = nil,
        startedAt: Date = .now
    ) {
        self.id = id
        self.modeRaw = mode.rawValue
        self.queuedQuestionIds = queuedQuestionIds
        self.filterJSON = filter?.storageValue
        self.paperId = paperId
        self.timeLimitSeconds = timeLimitSeconds
        self.position = 0
        self.flaggedQuestionIds = []
        self.startedAt = startedAt
        self.attempts = []
    }

    public var currentQuestionId: String? {
        queuedQuestionIds.indices.contains(position) ? queuedQuestionIds[position] : nil
    }

    public var isFinished: Bool { finishedAt != nil || position >= queuedQuestionIds.count }
}

@Model
public final class ExamAttempt {
    @Attribute(.unique) public var id: UUID = UUID()
    public var questionId: String = ""
    /// `nil` = left blank.
    public var selectedOption: Int?
    /// `nil` = blank, or a question without a key.
    public var isCorrect: Bool?
    public var responseTimeMs: Int = 0
    public var answeredAt: Date = Date.now
    public var bridgeOutcomeRaw: String?
    /// A plain id, not a relationship (see the file comment).
    public var linkedCardId: UUID?
    public var run: ExamRun?

    public var bridgeOutcome: ExamBridgeOutcome? {
        get { bridgeOutcomeRaw.flatMap(ExamBridgeOutcome.init(rawValue:)) }
        set { bridgeOutcomeRaw = newValue?.rawValue }
    }

    public var result: ExamResult {
        guard selectedOption != nil else { return .blank }
        guard let isCorrect else { return .unscored }
        return isCorrect ? .correct : .wrong
    }

    public init(
        id: UUID = UUID(),
        questionId: String,
        selectedOption: Int?,
        isCorrect: Bool?,
        responseTimeMs: Int,
        answeredAt: Date = .now,
        bridgeOutcome: ExamBridgeOutcome? = nil
    ) {
        self.id = id
        self.questionId = questionId
        self.selectedOption = selectedOption
        self.isCorrect = isCorrect
        self.responseTimeMs = responseTimeMs
        self.answeredAt = answeredAt
        self.bridgeOutcomeRaw = bridgeOutcome?.rawValue
    }
}

/// Everything known about one question across runs. Kept whether or not the
/// question is in the imported bank: a rebuilt bank that drops a question
/// must not drop the owner's history with it (plan §7.1) — Ayarlar counts
/// those as "bankada yok".
@Model
public final class ExamQuestionState {
    @Attribute(.unique) public var questionId: String = ""
    /// Card ids the owner linked through the bridge, as strings.
    public var linkedCardIds: [String] = []
    public var gapStatusRaw: String = ExamGapStatus.noGap.rawValue
    public var gapOpenedAt: Date?
    public var gapClosedAt: Date?
    public var closedByCardId: String?
    public var attemptCount: Int = 0
    public var wrongCount: Int = 0
    public var lastResultRaw: String?
    public var lastAnsweredAt: Date?
    public var reportedIssueRaw: String?

    public init(questionId: String) {
        self.questionId = questionId
        self.linkedCardIds = []
        self.gapStatusRaw = ExamGapStatus.noGap.rawValue
        self.attemptCount = 0
        self.wrongCount = 0
    }

    public var lastResult: ExamResult? {
        get { lastResultRaw.flatMap(ExamResult.init(rawValue:)) }
        set { lastResultRaw = newValue?.rawValue }
    }

    public var reportedIssue: ExamReportedIssue? {
        get { reportedIssueRaw.flatMap(ExamReportedIssue.init(rawValue:)) }
        set { reportedIssueRaw = newValue?.rawValue }
    }

    public var linkedCards: [UUID] { linkedCardIds.compactMap(UUID.init(uuidString:)) }

    public var gap: ExamGap {
        get {
            ExamGap(
                status: ExamGapStatus(rawValue: gapStatusRaw) ?? .noGap,
                openedAt: gapOpenedAt,
                closedAt: gapClosedAt,
                closedByCardId: closedByCardId.flatMap(UUID.init(uuidString:))
            )
        }
        set {
            gapStatusRaw = newValue.status.rawValue
            gapOpenedAt = newValue.openedAt
            gapClosedAt = newValue.closedAt
            closedByCardId = newValue.closedByCardId?.uuidString
        }
    }

    public var progress: ExamProgress {
        ExamProgress(
            attemptCount: attemptCount,
            lastResult: lastResult,
            lastAnsweredAt: lastAnsweredAt,
            gapStatus: gap.status
        )
    }

    /// Folds one answer in. The only writer of the counters, so a run and a
    /// restored backup (Faz B) cannot count differently.
    public func record(_ result: ExamResult, at date: Date) {
        attemptCount += 1
        if result.isMiss { wrongCount += 1 }
        // A restored or out-of-order answer must not overwrite a newer one.
        if lastAnsweredAt.map({ date >= $0 }) ?? true {
            lastResult = result
            lastAnsweredAt = date
        }
    }

    public func link(_ cardId: UUID) {
        let raw = cardId.uuidString
        if !linkedCardIds.contains(raw) { linkedCardIds.append(raw) }
    }

    public func unlink(_ cardId: UUID) {
        linkedCardIds.removeAll { $0 == cardId.uuidString }
    }
}
