import Foundation

/// How one answer to a past exam question came out.
public enum ExamResult: String, Codable, CaseIterable, Sendable {
    case correct
    case wrong
    /// Left empty ("Boş bırak") — in TUS terms neither right nor wrong, but for
    /// the owner a question they could not answer, so it counts with the
    /// wrong ones wherever the question is "can I do this?".
    case blank
    /// Answered, but the question has no key (a read-only question).
    case unscored

    /// The one place the rule lives: an empty selection is blank whatever the
    /// key, a keyless question can only be unscored.
    public static func of(selectedOption: Int?, answer: Int?) -> ExamResult {
        guard let selectedOption else { return .blank }
        guard let answer else { return .unscored }
        return selectedOption == answer ? .correct : .wrong
    }

    /// Not answered correctly when it could have been.
    public var isMiss: Bool { self == .wrong || self == .blank }
}

/// Where a question stands in "Kitaba dönünce" (plan §7.6).
public enum ExamGapStatus: String, Codable, CaseIterable, Sendable {
    /// Spelled out, not `none`, for the reason `ExamKeySource.missing` gives.
    case noGap = "none"
    case open
    case closed
    case dismissed
}

/// What the owner's history says about one question — the part of
/// `ExamQuestionState` the filter and the queue need, free of SwiftData.
public struct ExamProgress: Equatable, Sendable {
    public var attemptCount: Int
    public var lastResult: ExamResult?
    public var lastAnsweredAt: Date?
    public var gapStatus: ExamGapStatus

    public init(
        attemptCount: Int = 0,
        lastResult: ExamResult? = nil,
        lastAnsweredAt: Date? = nil,
        gapStatus: ExamGapStatus = .noGap
    ) {
        self.attemptCount = attemptCount
        self.lastResult = lastResult
        self.lastAnsweredAt = lastAnsweredAt
        self.gapStatus = gapStatus
    }

    public static let untouched = ExamProgress()

    public var isAttempted: Bool { attemptCount > 0 }
    /// "Yanlışlarım": the last answer was wrong or left blank.
    public var isWrong: Bool { lastResult?.isMiss == true }
}

/// Temel and Klinik — what a student means by "test". The second Temel test
/// of 2011/1 and 2012/1 is Temel.
public enum ExamTestGroup: String, Codable, CaseIterable, Sendable {
    case temel
    case klinik

    public init(_ test: ExamTest) {
        self = test == .klinik ? .klinik : .temel
    }
}

/// Which slice of the owner's history to draw from.
public enum ExamProgressFilter: String, Codable, CaseIterable, Sendable {
    case all
    case unsolved
    case wrong
    case gaps
}

/// Pratik's filter (plan §7.2). Every set is "empty means all", like
/// `ExerciseFilter`, so ticking nothing never means "no questions".
public struct ExamFilter: Equatable, Sendable {
    /// ÖSYM's subject name — the twelve a TUS student knows, Histoloji apart
    /// from Fizyoloji. Topics come from the mapped app subject's list.
    public var subject: String?
    public var topic: TopicFilter
    public var minYear: Int?
    public var maxYear: Int?
    public var sessions: Set<Int>
    public var testGroups: Set<ExamTestGroup>
    public var sourceKinds: Set<ExamSourceKind>
    public var progress: ExamProgressFilter
    /// Questions whose figure is part of the question (`required`) or pointed
    /// at (`reference`). On by default: the crop is shown.
    public var includeFigures: Bool
    /// ≤ 2012 (plan D7, owner's K2: on, badged).
    public var includeOld: Bool
    /// Keyless questions, answered without a mark (plan D6: off by default —
    /// an unscoreable question breaks both Pratik's count and a mock's net).
    public var includeKeyless: Bool

    public init(
        subject: String? = nil,
        topic: TopicFilter = .all,
        minYear: Int? = nil,
        maxYear: Int? = nil,
        sessions: Set<Int> = [],
        testGroups: Set<ExamTestGroup> = [],
        sourceKinds: Set<ExamSourceKind> = [],
        progress: ExamProgressFilter = .all,
        includeFigures: Bool = true,
        includeOld: Bool = true,
        includeKeyless: Bool = false
    ) {
        self.subject = subject
        self.topic = topic
        self.minYear = minYear
        self.maxYear = maxYear
        self.sessions = sessions
        self.testGroups = testGroups
        self.sourceKinds = sourceKinds
        self.progress = progress
        self.includeFigures = includeFigures
        self.includeOld = includeOld
        self.includeKeyless = includeKeyless
    }

    public var isActive: Bool { self != ExamFilter() }

    /// Whether a question may be answered at all under this filter — before
    /// any of the owner's choices. Cancelled, compiler-modified and
    /// unresolved questions never are; keyless ones only when asked for.
    public func isEligible(_ question: ExamQuestion) -> Bool {
        question.isScoreable || (includeKeyless && question.isReadOnly)
    }

    public func matches(_ question: ExamQuestion, paper: ExamPaper?, progress state: ExamProgress) -> Bool {
        guard isEligible(question) else { return false }
        guard LibraryCardFilter.matches(
            subject: question.osymSubject,
            topic: question.topic,
            subjectFilter: subject,
            topicFilter: topic
        ) else { return false }

        let id = ExamQuestionID(question.id)
        if let year = id?.year {
            if let minYear, year < minYear { return false }
            if let maxYear, year > maxYear { return false }
            if !includeOld, year <= ExamQuestion.lastOldYear { return false }
        }
        if !sessions.isEmpty, let session = id?.session, !sessions.contains(session) { return false }
        if !testGroups.isEmpty, let test = id?.test, !testGroups.contains(ExamTestGroup(test)) { return false }
        if !sourceKinds.isEmpty {
            // A question's source is where its *text* came from; the paper
            // tells an official full booklet from ÖSYM's partial one.
            guard let paper, sourceKinds.contains(paper.sourceKind) else { return false }
        }
        if !includeFigures, question.hasFigure { return false }

        switch progress {
        case .all: return true
        case .unsolved: return !state.isAttempted
        case .wrong: return state.isWrong
        case .gaps: return state.gapStatus == .open
        }
    }
}

extension ExamFilter {
    /// A small explicit shape for `ExamRun.filterJSON` and the remembered
    /// "last filter", for the reason `ExerciseFilter.Storage` gives: a stored
    /// run must keep meaning the same thing as this type evolves.
    private struct Storage: Codable {
        var subject: String?
        var topic: String?
        var minYear: Int?
        var maxYear: Int?
        var sessions: [Int]
        var testGroups: [String]
        var sourceKinds: [String]
        var progress: String
        var includeFigures: Bool
        var includeOld: Bool
        var includeKeyless: Bool
    }

    public var storageValue: String? {
        let storage = Storage(
            subject: subject,
            topic: topic.storageValue,
            minYear: minYear,
            maxYear: maxYear,
            sessions: sessions.sorted(),
            testGroups: ExamTestGroup.allCases.filter(testGroups.contains).map(\.rawValue),
            sourceKinds: ExamSourceKind.allCases.filter(sourceKinds.contains).map(\.rawValue),
            progress: progress.rawValue,
            includeFigures: includeFigures,
            includeOld: includeOld,
            includeKeyless: includeKeyless
        )
        guard let data = try? JSONEncoder().encode(storage) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Unreadable storage falls back to the default filter rather than
    /// throwing — `ExerciseFilter.fromStorage`'s rule.
    public static func fromStorage(_ raw: String?) -> ExamFilter {
        guard let raw, let data = raw.data(using: .utf8),
              let storage = try? JSONDecoder().decode(Storage.self, from: data)
        else { return ExamFilter() }
        return ExamFilter(
            subject: storage.subject,
            topic: TopicFilter.fromStorage(storage.topic),
            minYear: storage.minYear,
            maxYear: storage.maxYear,
            sessions: Set(storage.sessions.filter { $0 == 1 || $0 == 2 }),
            testGroups: Set(storage.testGroups.compactMap(ExamTestGroup.init(rawValue:))),
            sourceKinds: Set(storage.sourceKinds.compactMap(ExamSourceKind.init(rawValue:))),
            progress: ExamProgressFilter(rawValue: storage.progress) ?? .all,
            includeFigures: storage.includeFigures,
            includeOld: storage.includeOld,
            includeKeyless: storage.includeKeyless
        )
    }
}
