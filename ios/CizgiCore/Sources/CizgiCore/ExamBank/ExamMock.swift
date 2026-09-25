import Foundation

/// A mock's countdown (plan §7.4 e), as a value so the rules are testable.
///
/// Wall-clock, like the exam hall: time runs while the app is in the
/// background or not running at all. The only way to stop it is the pause
/// button, and every paused second is kept (`pausedSeconds`) so the result
/// can say how long the sitting really took. A clock that paused itself
/// whenever the phone locked would hand out free minutes nobody asked for.
public struct ExamMockClock: Equatable, Sendable {
    public let startedAt: Date
    /// `nil` = untimed.
    public let limitSeconds: Int?
    /// Pauses already over.
    public let pausedSeconds: Double
    /// The pause in progress, if any.
    public let pausedAt: Date?

    public init(startedAt: Date, limitSeconds: Int?, pausedSeconds: Double = 0, pausedAt: Date? = nil) {
        self.startedAt = startedAt
        self.limitSeconds = limitSeconds
        self.pausedSeconds = pausedSeconds
        self.pausedAt = pausedAt
    }

    public var isPaused: Bool { pausedAt != nil }

    /// Time spent sitting the exam, pauses excluded.
    public func activeSeconds(at now: Date) -> Double {
        max(0, (pausedAt ?? now).timeIntervalSince(startedAt) - pausedSeconds)
    }

    public func remainingSeconds(at now: Date) -> Double? {
        limitSeconds.map { max(0, Double($0) - activeSeconds(at: now)) }
    }

    public func isExpired(at now: Date) -> Bool {
        remainingSeconds(at: now) == 0
    }

    /// When the time runs out if nothing pauses it — `nil` while paused or
    /// untimed. Also the finishing time of a mock that ran out while the app
    /// was closed: it ended then, not when the owner came back.
    public var deadline: Date? {
        guard let limitSeconds, pausedAt == nil else { return nil }
        return startedAt.addingTimeInterval(Double(limitSeconds) + pausedSeconds)
    }

    public func totalPausedSeconds(at now: Date) -> Double {
        pausedSeconds + (pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    public func pausing(at now: Date) -> ExamMockClock {
        guard pausedAt == nil else { return self }
        return ExamMockClock(startedAt: startedAt, limitSeconds: limitSeconds, pausedSeconds: pausedSeconds, pausedAt: now)
    }

    public func resuming(at now: Date) -> ExamMockClock {
        guard let pausedAt else { return self }
        return ExamMockClock(
            startedAt: startedAt,
            limitSeconds: limitSeconds,
            pausedSeconds: pausedSeconds + max(0, now.timeIntervalSince(pausedAt)),
            pausedAt: nil
        )
    }
}

/// Builds mocks (plan §7.4 b): a real paper as ÖSYM printed it, or a mixed
/// sitting with a real paper's subject distribution.
public enum ExamMockComposer {
    /// A question a mock can put on screen: five options and a text the
    /// bank vouches for. Keyless and compiler-modified questions sit in their
    /// paper as they did on the day — they are shown and simply not scored;
    /// cancelled slots (no options) and unresolved ones are left out.
    public static func isMockable(_ question: ExamQuestion) -> Bool {
        question.options.count == 5 && question.status != .cancelled && question.status != .needsHuman
    }

    /// The paper's questions in booklet order.
    public static func paperQueue(_ bank: ExamBank, paper: ExamPaper) -> [String] {
        (bank.questionIdsByPaper[paper.id] ?? []).filter { id in
            bank.question(id).map(isMockable) ?? false
        }
    }

    /// How many of a queue count towards the net.
    public static func scoreableCount(_ bank: ExamBank, queue: [String]) -> Int {
        queue.filter(bank.scoreableIds.contains).count
    }

    /// The paper's own limit (`ExamTimeLimit`), shrunk in proportion when
    /// the bank holds only part of the paper — ÖSYM's partial booklets show
    /// about a tenth of their questions.
    public static func timeLimitSeconds(_ bank: ExamBank, paper: ExamPaper, questionCount: Int) -> Int {
        let full = ExamTimeLimit.seconds(for: paper, sittingQuestionCount: bank.sittingQuestionCount(for: paper))
        guard paper.questionCount > 0 else { return full }
        return Int((Double(full) * Double(questionCount) / Double(paper.questionCount)).rounded())
    }

    /// The paper whose subject shares a mixed mock copies: the latest full
    /// paper of the group — a whole booklet (not ÖSYM's partial one) with at
    /// least nine in ten of its questions in the bank.
    public static func template(_ bank: ExamBank, group: ExamTestGroup) -> ExamPaper? {
        let test: ExamTest = group == .temel ? .temel : .klinik
        return bank.papers
            .filter { paper in
                paper.test == test && paper.sourceKind != .osymPartial
                    && Double(bank.questionIdsByPaper[paper.id]?.count ?? 0) >= 0.9 * Double(paper.questionCount)
            }
            .max { ($0.year, $0.session) < ($1.year, $1.session) }
    }

    /// Question count per ÖSYM subject in a paper, in booklet order.
    public static func subjectCounts(_ bank: ExamBank, paper: ExamPaper) -> [(subject: String, count: Int)] {
        var counts: [String: Int] = [:]
        for id in bank.questionIdsByPaper[paper.id] ?? [] {
            if let subject = bank.question(id)?.osymSubject { counts[subject, default: 0] += 1 }
        }
        return ExamQuestion.osymSubjects.compactMap { subject in
            counts[subject].map { (subject, $0) }
        }
    }

    /// Splits `total` in proportion to `weights` with whole numbers that add
    /// up exactly — largest remainder, ties to the earlier entry.
    public static func apportion(_ total: Int, weights: [Int]) -> [Int] {
        let sum = weights.reduce(0, +)
        guard total > 0, sum > 0 else { return weights.map { _ in 0 } }
        let exact = weights.map { Double(total) * Double($0) / Double(sum) }
        var quotas = exact.map { Int($0.rounded(.down)) }
        let order = exact.indices.sorted { left, right in
            let l = exact[left] - Double(quotas[left]), r = exact[right] - Double(quotas[right])
            return l != r ? l > r : left < right
        }
        for index in order.prefix(total - quotas.reduce(0, +)) { quotas[index] += 1 }
        return quotas
    }

    /// A mixed mock of `count` scoreable questions from one test group,
    /// shared out like the template paper. Unanswered questions first within
    /// each subject; subjects in booklet order, the way the exam reads.
    /// A subject that runs short simply gives fewer questions — the mock is
    /// never padded from a subject the template did not have.
    public static func mixedQueue(
        _ bank: ExamBank,
        group: ExamTestGroup,
        count: Int,
        progress: [String: ExamProgress],
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        guard let template = template(bank, group: group) else { return [] }
        let shares = subjectCounts(bank, paper: template)
        let quotas = apportion(count, weights: shares.map(\.count))

        var bySubject: [String: [ExamQuestion]] = [:]
        for question in bank.questions where question.isScoreable {
            guard let id = ExamQuestionID(question.id), ExamTestGroup(id.test) == group,
                  let subject = question.osymSubject else { continue }
            bySubject[subject, default: []].append(question)
        }

        var queue: [String] = []
        for (share, quota) in zip(shares, quotas) where quota > 0 {
            let pool = bySubject[share.subject] ?? []
            let fresh = pool.filter { !(progress[$0.id]?.isAttempted ?? false) }.shuffled(using: &generator)
            let seen = pool.filter { progress[$0.id]?.isAttempted ?? false }.shuffled(using: &generator)
            queue.append(contentsOf: (fresh + seen).prefix(quota).map(\.id))
        }
        return queue
    }
}

extension ExamBank {
    /// A mock is scored over its whole queue (plan §7.4 f): a question never
    /// answered is blank, as on the answer sheet; one without a key is
    /// unscored whatever was marked.
    public func mockScoredAnswers(
        queue: [String],
        answers: [String: (selectedOption: Int?, responseTimeMs: Int)]
    ) -> [ExamScoredAnswer] {
        queue.compactMap { id in
            guard let question = questionsById[id] else { return nil }
            let answer = answers[id]
            let key = question.isScoreable ? question.answer : nil
            let result = question.isScoreable
                ? ExamResult.of(selectedOption: answer?.selectedOption, answer: key)
                : .unscored
            return ExamScoredAnswer(
                questionId: id,
                subject: question.osymSubject,
                result: result,
                responseTimeMs: answer?.responseTimeMs ?? 0,
                penalty: papersById[question.paperId]?.penalty ?? .unknown
            )
        }
    }
}
