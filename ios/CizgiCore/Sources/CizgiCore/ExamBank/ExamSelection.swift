import Foundation

/// The question-shaped facts the queue needs, free of SwiftData.
public struct ExamSelectionCandidate: Equatable, Sendable {
    public let id: String
    /// ÖSYM subject — what the interleave spreads across.
    public let subject: String?
    public let similarTo: [String]
    public let progress: ExamProgress

    public init(id: String, subject: String?, similarTo: [String] = [], progress: ExamProgress = .untouched) {
        self.id = id
        self.subject = subject
        self.similarTo = similarTo
        self.progress = progress
    }
}

/// Which questions a run holds and in what order (plan §7.2).
///
/// Three steps, each for a reason:
///
/// 1. **Priority.** A fresh run puts questions never answered before the
///    rest; "Yanlışlarım" puts the oldest miss first, since that is the one
///    most likely forgotten again.
/// 2. **Picking** walks that order and skips a question whose `similarTo`
///    partner is already in — two near-identical questions in one sitting
///    test recall of the first, not knowledge.
/// 3. **Interleave.** A run drawn from twelve subjects would otherwise come
///    out in clumps, which is not how the exam reads. Each subject's picks
///    are spread evenly through the run (a question's slot is its rank within
///    its subject divided by that subject's count), so a subject with a tenth
///    of the questions turns up about every tenth question — plain
///    round-robin would instead empty the small subjects in the first few
///    turns. Order *within* a subject is never changed, so the oldest miss is
///    still the first of its subject to come up.
///
/// The generator is injected, as `ExerciseSession` does, so tests can pin it.
public enum ExamSelection {
    public enum Order: Equatable, Sendable {
        /// Unanswered first, then the rest; random within each.
        case fresh
        /// Oldest last answer first (Yanlışlarım, Kitaba dönünce).
        case oldestFirst
    }

    public static func queue(
        from candidates: [ExamSelectionCandidate],
        limit: Int?,
        order: Order,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        let prioritised: [ExamSelectionCandidate]
        switch order {
        case .fresh:
            let unanswered = candidates.filter { !$0.progress.isAttempted }.shuffled(using: &generator)
            let answered = candidates.filter { $0.progress.isAttempted }.shuffled(using: &generator)
            prioritised = unanswered + answered
        case .oldestFirst:
            prioritised = candidates.sorted { left, right in
                switch (left.progress.lastAnsweredAt, right.progress.lastAnsweredAt) {
                case let (l?, r?) where l != r: return l < r
                case (nil, _?): return true
                case (_?, nil): return false
                default: return left.id < right.id
                }
            }
        }

        let cap = limit.map { max(0, $0) } ?? prioritised.count
        var picked: [ExamSelectionCandidate] = []
        var taken: Set<String> = []
        // Near-duplicates exclude each other in both directions: only one side
        // of a pair may list the other.
        var blocked: Set<String> = []
        for candidate in prioritised where picked.count < cap {
            guard !taken.contains(candidate.id), !blocked.contains(candidate.id) else { continue }
            if candidate.similarTo.contains(where: taken.contains) { continue }
            picked.append(candidate)
            taken.insert(candidate.id)
            blocked.formUnion(candidate.similarTo)
        }

        return interleave(picked, jitter: order == .fresh, using: &generator)
    }

    /// Spreads each subject's picks evenly through the run, keeping their
    /// order within the subject.
    static func interleave(
        _ picked: [ExamSelectionCandidate],
        jitter: Bool,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        var bySubject: [String: [ExamSelectionCandidate]] = [:]
        var subjectOrder: [String] = []
        for candidate in picked {
            let key = candidate.subject ?? ""
            if bySubject[key] == nil { subjectOrder.append(key) }
            bySubject[key, default: []].append(candidate)
        }
        if jitter { subjectOrder.shuffle(using: &generator) }
        let rankOfSubject = Dictionary(uniqueKeysWithValues: subjectOrder.enumerated().map { ($1, $0) })

        var slots: [(key: Double, subjectRank: Int, id: String)] = []
        for subject in subjectOrder {
            let group = bySubject[subject] ?? []
            // Where in its stride the subject starts. Fixed at the middle for
            // an ordered run so the same history always queues the same way.
            let offset = jitter ? Double.random(in: 0..<1, using: &generator) : 0.5
            for (index, candidate) in group.enumerated() {
                let key = (Double(index) + offset) / Double(group.count)
                slots.append((key, rankOfSubject[subject] ?? 0, candidate.id))
            }
        }
        return slots
            .sorted { $0.key != $1.key ? $0.key < $1.key : $0.subjectRank < $1.subjectRank }
            .map(\.id)
    }
}
