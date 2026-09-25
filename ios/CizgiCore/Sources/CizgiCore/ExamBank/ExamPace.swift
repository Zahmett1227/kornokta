import Foundation

/// How long the owner takes per question, and so how many fit in a time box
/// (plan §7.2).
///
/// `ReviewPace`'s shape — median of the last fifty, clamped outliers — with its
/// own numbers: a card is recalled in seconds, a TUS vignette is read in about
/// a minute, and `ReviewPace` clamps at 60 s, which would make every slow
/// question look like a fast one.
public enum ExamPace {
    /// The 2012–2015 booklets give 150 minutes for 120 questions.
    public static let fallbackSecondsPerQuestion: Double = 75
    public static let plausibleSeconds: ClosedRange<Double> = 10...300
    public static let sampleSize = 50

    public static func secondsPerQuestion(recentResponseTimesMs: [Int]) -> Double {
        let samples = recentResponseTimesMs
            .prefix(sampleSize)
            .map { min(max(Double($0) / 1_000, plausibleSeconds.lowerBound), plausibleSeconds.upperBound) }
            .sorted()
        guard !samples.isEmpty else { return fallbackSecondsPerQuestion }
        let middle = samples.count / 2
        return samples.count.isMultiple(of: 2) ? (samples[middle - 1] + samples[middle]) / 2 : samples[middle]
    }

    /// At least one, so a time box never yields an empty run.
    public static func questionCount(forMinutes minutes: Int, secondsPerQuestion: Double) -> Int {
        guard minutes > 0, secondsPerQuestion > 0 else { return 1 }
        return max(1, Int((Double(minutes) * 60 / secondsPerQuestion).rounded(.down)))
    }
}

/// A paper's time limit for a mock (plan §7.2, used from Faz A3).
public enum ExamTimeLimit {
    public static let defaultSecondsPerQuestion = 75

    /// The booklet's own limit when it prints one; a sitting's shared limit
    /// split by question count when only that is printed (2009–2011: 210
    /// minutes for both tests); otherwise 75 seconds a question.
    public static func seconds(
        for paper: ExamPaper,
        sittingQuestionCount: Int,
        secondsPerQuestion: Int = defaultSecondsPerQuestion
    ) -> Int {
        if let minutes = paper.timeLimitMinutes { return minutes * 60 }
        if let minutes = paper.sessionTimeLimitMinutes, sittingQuestionCount > 0 {
            return Int((Double(minutes * 60) * Double(paper.questionCount) / Double(sittingQuestionCount)).rounded())
        }
        return paper.questionCount * secondsPerQuestion
    }
}
