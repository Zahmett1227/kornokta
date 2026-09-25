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
        for run in open { close(run) }
    }

    /// Ends a run the owner walked away from. A mock is handed in as it
    /// stands — its marks become history then, never silently dropped — and
    /// ends when its clock did if that came first.
    func close(_ run: ExamRun, at now: Date = .now) {
        guard run.finishedAt == nil else { return }
        if run.mode == .mock {
            let deadline = run.clock.deadline
            let expired = deadline.map { $0 <= now } ?? false
            ExamRecorder(context: context).submitMock(run, bank: bank, at: expired ? deadline! : now, byTimeLimit: expired)
        } else {
            run.finishedAt = now
        }
    }

    /// Deneme on a real paper: its questions in booklet order, its own time
    /// limit (shrunk for a partial booklet).
    func startMock(paper: ExamPaper) -> ExamRun? {
        let queue = ExamMockComposer.paperQueue(bank, paper: paper)
        guard !queue.isEmpty else { return nil }
        closeOpenRuns()
        let run = ExamRun(
            mode: .mock,
            queuedQuestionIds: queue,
            paperId: paper.id,
            timeLimitSeconds: ExamMockComposer.timeLimitSeconds(bank, paper: paper, questionCount: queue.count)
        )
        context.insert(run)
        try? context.save()
        return run
    }

    /// "Karma deneme": `count` questions with the latest full paper's subject
    /// shares, timed at that paper's rate. The group is kept in the run's
    /// filter so the result can compare it with earlier mixed mocks.
    func startMixedMock(group: ExamTestGroup, count: Int, progress: [String: ExamProgress]) -> ExamRun? {
        guard let template = ExamMockComposer.template(bank, group: group) else { return nil }
        var generator = SystemRandomNumberGenerator()
        let queue = ExamMockComposer.mixedQueue(bank, group: group, count: count, progress: progress, using: &generator)
        guard !queue.isEmpty else { return nil }
        closeOpenRuns()
        let run = ExamRun(
            mode: .mock,
            queuedQuestionIds: queue,
            filter: ExamFilter(testGroups: [group]),
            timeLimitSeconds: ExamMockComposer.timeLimitSeconds(bank, paper: template, questionCount: queue.count)
        )
        context.insert(run)
        try? context.save()
        return run
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
