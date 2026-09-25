import Foundation
import SwiftData
import CizgiCore

/// How many questions a run should hold: a count, a time box translated
/// through the owner's own measured pace (`ExamPace`), or everything.
enum ExamBudget: Hashable {
    case questions(Int)
    case minutes(Int)
    case all

    static let questionPresets = [10, 20, 40]
    static let minutePresets = [10, 20, 40]

    func limit(secondsPerQuestion: Double) -> Int? {
        switch self {
        case .questions(let count): return count
        case .minutes(let minutes): return ExamPace.questionCount(forMinutes: minutes, secondsPerQuestion: secondsPerQuestion)
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .questions(let count): return "\(count)"
        case .minutes(let minutes): return "\(minutes) dk"
        case .all: return "Tümü"
        }
    }
}

/// Starts runs — the one place a queue becomes an `ExamRun`, so Pratik,
/// Yanlışlarım and Kitaba dönünce cannot build theirs differently.
@MainActor
struct ExamRunLauncher {
    let context: ModelContext
    let bank: ExamBank

    /// Everything the owner has done, keyed by question id.
    static func progressMap(_ states: [ExamQuestionState]) -> [String: ExamProgress] {
        Dictionary(states.map { ($0.questionId, $0.progress) }, uniquingKeysWith: { first, _ in first })
    }

    /// Closes any run still open and returns the new one, or `nil` when the
    /// filter admits nothing. One open run at a time: the home screen offers
    /// to resume exactly one.
    func start(
        mode: ExamRunMode,
        filter: ExamFilter,
        progress: [String: ExamProgress],
        limit: Int?,
        order: ExamSelection.Order
    ) -> ExamRun? {
        let questions = bank.questions(matching: filter, progress: progress)
        var generator = SystemRandomNumberGenerator()
        let queue = ExamSelection.queue(
            from: bank.selectionCandidates(for: questions, progress: progress),
            limit: limit,
            order: order,
            using: &generator
        )
        guard !queue.isEmpty else { return nil }

        closeOpenRuns()
        let run = ExamRun(mode: mode, queuedQuestionIds: queue, filter: filter)
        context.insert(run)
        try? context.save()
        return run
    }

    func closeOpenRuns() {
        let open = (try? context.fetch(FetchDescriptor<ExamRun>(predicate: #Predicate { $0.finishedAt == nil }))) ?? []
        for run in open { run.finishedAt = .now }
    }

    /// The owner's pace, from the last fifty answers.
    static func secondsPerQuestion(context: ModelContext) -> Double {
        var descriptor = FetchDescriptor<ExamAttempt>(sortBy: [SortDescriptor(\.answeredAt, order: .reverse)])
        descriptor.fetchLimit = ExamPace.sampleSize
        let recent = (try? context.fetch(descriptor)) ?? []
        return ExamPace.secondsPerQuestion(recentResponseTimesMs: recent.map(\.responseTimeMs))
    }
}

/// The remembered Pratik filter — the plan's "son kullanılan filtreyle hemen
/// başlar". Per device, like the rest of the app's UI state.
enum ExamFilterMemory {
    private static let key = "cizgi.exam.filter.v1"

    static func load() -> ExamFilter {
        ExamFilter.fromStorage(UserDefaults.standard.string(forKey: key))
    }

    static func save(_ filter: ExamFilter) {
        UserDefaults.standard.set(filter.storageValue, forKey: key)
    }
}
