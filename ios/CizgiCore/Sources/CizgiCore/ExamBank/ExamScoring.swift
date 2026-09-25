import Foundation

/// One answered question, as scoring needs it.
public struct ExamScoredAnswer: Equatable, Sendable {
    public let questionId: String
    /// ÖSYM subject, for the per-subject breakdown.
    public let subject: String?
    public let result: ExamResult
    public let responseTimeMs: Int
    public let penalty: ExamPenalty

    public init(questionId: String, subject: String?, result: ExamResult, responseTimeMs: Int, penalty: ExamPenalty) {
        self.questionId = questionId
        self.subject = subject
        self.result = result
        self.responseTimeMs = responseTimeMs
        self.penalty = penalty
    }
}

/// Counts and net for a set of answers (plan §7.2, owner's K7).
public struct ExamScore: Equatable, Sendable {
    public let correct: Int
    public let wrong: Int
    public let blank: Int
    public let unscored: Int
    /// D − Y/4.
    public let net: Double
    /// Some answer came from a paper whose booklet does not print the rule, so
    /// the quarter penalty is the assumed default, not the stated one — the
    /// result screen says "varsayılan" next to the net.
    public let usesDefaultPenalty: Bool
    public let averageSeconds: Double?

    /// Scored questions only: an unscored answer has no right or wrong.
    public var answered: Int { correct + wrong + blank }
    /// Share of scored questions answered correctly; `nil` with none.
    public var accuracy: Double? { answered > 0 ? Double(correct) / Double(answered) : nil }
}

public struct ExamSubjectScore: Equatable, Sendable {
    public let subject: String?
    public let score: ExamScore
}

public enum ExamScoring {
    /// "Yanlışların dörtte biri doğruları götürür" — printed in the 2009–2015
    /// booklets, assumed for the rest.
    public static let wrongPenalty = 0.25

    public static func score(_ answers: [ExamScoredAnswer]) -> ExamScore {
        var correct = 0, wrong = 0, blank = 0, unscored = 0
        var usesDefault = false
        for answer in answers {
            switch answer.result {
            case .correct: correct += 1
            case .wrong: wrong += 1
            case .blank: blank += 1
            case .unscored: unscored += 1
            }
            if answer.result != .unscored, answer.penalty == .unknown { usesDefault = true }
        }
        let times = answers.map(\.responseTimeMs)
        return ExamScore(
            correct: correct,
            wrong: wrong,
            blank: blank,
            unscored: unscored,
            net: Double(correct) - Double(wrong) * wrongPenalty,
            usesDefaultPenalty: usesDefault,
            averageSeconds: times.isEmpty ? nil : Double(times.reduce(0, +)) / Double(times.count) / 1_000
        )
    }

    /// Per ÖSYM subject, in booklet order; subjects with no answer are left
    /// out, answers without a subject come last.
    public static func bySubject(_ answers: [ExamScoredAnswer]) -> [ExamSubjectScore] {
        let grouped = Dictionary(grouping: answers, by: \.subject)
        let known = ExamQuestion.osymSubjects.compactMap { subject -> ExamSubjectScore? in
            guard let group = grouped[subject] else { return nil }
            return ExamSubjectScore(subject: subject, score: score(group))
        }
        let unlisted = grouped.keys
            .compactMap { $0 }
            .filter { !ExamQuestion.osymSubjects.contains($0) }
            .sorted()
            .map { ExamSubjectScore(subject: $0, score: score(grouped[$0] ?? [])) }
        let none = grouped[nil].map { [ExamSubjectScore(subject: nil, score: score($0))] } ?? []
        return known + unlisted + none
    }
}
