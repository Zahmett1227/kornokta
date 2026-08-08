import Foundation

/// One recorded practice answer, flattened out of `ExerciseAttempt` so the
/// ranking below stays free of SwiftData and testable by `swift test`.
public struct ExerciseOutcome: Equatable, Sendable {
    public let cardId: UUID
    public let result: ExerciseResult
    public let answeredAt: Date

    public init(cardId: UUID, result: ExerciseResult, answeredAt: Date) {
        self.cardId = cardId
        self.result = result
        self.answeredAt = answeredAt
    }
}

/// How much a card's practice history argues that it is still weak *today*.
///
/// The first version of this summed every attempt ever recorded, counted a
/// miss as +3 and a correct answer as 0. That never converges: a card missed
/// once keeps its +3 for ever, so it comes back in every "Zayıf noktalar"
/// run, and every fresh miss adds another +3 while learning it back subtracts
/// nothing. The list a user works hardest on would be exactly the list that
/// can never shrink.
///
/// Two properties fix that. Answering correctly *removes* weight, so a card
/// genuinely relearned sinks below cards never practised at all. And every
/// attempt decays with age, so today's mistake outranks last month's and
/// evidence past `window` is simply gone — a miss from six weeks ago says
/// nothing about what the user knows now.
public enum ExercisePracticeWeight {
    /// Attempts older than this contribute nothing at all.
    public static let window: TimeInterval = 30 * 24 * 3600
    /// An attempt's contribution halves every 7 days inside the window.
    public static let halfLife: TimeInterval = 7 * 24 * 3600

    /// Deliberately asymmetric: a miss is stronger evidence of a gap than a
    /// correct answer is of mastery, but a correct answer still has to move
    /// the card in the right direction.
    static func baseWeight(for result: ExerciseResult) -> Double {
        switch result {
        case .missed: return 3
        case .unsure: return 1
        case .knew: return -2
        }
    }

    /// Scores may go negative — a recently-proven card belongs *below* one
    /// that has never been practised, not level with it.
    public static func scores(
        for outcomes: [ExerciseOutcome],
        now: Date
    ) -> [UUID: Double] {
        outcomes.reduce(into: [UUID: Double]()) { scores, outcome in
            let age = now.timeIntervalSince(outcome.answeredAt)
            // Clock changes and restored backups can produce answers stamped in
            // the future; treat them as fresh rather than amplifying them.
            let clampedAge = max(0, age)
            guard clampedAge <= window else { return }
            let decay = pow(0.5, clampedAge / halfLife)
            scores[outcome.cardId, default: 0] += baseWeight(for: outcome.result) * decay
        }
    }
}

/// When a finished practice run stops being worth keeping.
///
/// `ExerciseAttempt` rows are written on every answer and read on the app's
/// launch screen (Egzersiz is the default tab, and its weak-point picker walks
/// the history). Nothing was ever deleting them, so the table only grew — the
/// same "collect and forget" shape §7.3 already flags on the server side, but
/// here it also gets slower the longer the app is used.
///
/// 90 days is comfortably past the 30-day window the scoring itself honours, so
/// pruning can never change a weak-point ranking; it only drops rows that were
/// already being ignored, plus the run summaries older than the three the start
/// screen shows.
public enum ExerciseHistory {
    public static let retention: TimeInterval = 90 * 24 * 3600

    /// An unfinished run is never expired, however old: it is the run the app
    /// restores on launch, and deleting it would silently discard work.
    public static func isExpired(finishedAt: Date?, now: Date) -> Bool {
        guard let finishedAt else { return false }
        return now.timeIntervalSince(finishedAt) > retention
    }
}

/// The card-shaped facts the weak-point ranking needs, without SwiftData.
public struct WeakPointCandidate: Equatable, Sendable {
    public let cardId: UUID
    public let lapseCount: Int
    public let lowConfidence: Bool
    public let stability: Double
    public let updatedAt: Date

    public init(
        cardId: UUID,
        lapseCount: Int,
        lowConfidence: Bool,
        stability: Double,
        updatedAt: Date
    ) {
        self.cardId = cardId
        self.lapseCount = lapseCount
        self.lowConfidence = lowConfidence
        self.stability = stability
        self.updatedAt = updatedAt
    }
}

public enum WeakPointRanking {
    /// Whether the deck holds any evidence against this card at all: a recent
    /// practice mistake, an FSRS lapse, or a card the server itself was unsure
    /// about.
    static func isWeak(_ candidate: WeakPointCandidate, score: Double) -> Bool {
        score > 0 || candidate.lapseCount > 0 || candidate.lowConfidence
    }

    /// Only the cards there is a reason to drill, weakest first.
    ///
    /// Ranking alone cannot answer this. Sorting a perfectly healthy deck still
    /// produces a first element, so taking the top 20 of it would offer twenty
    /// cards the user has never once got wrong under the heading "Zayıf
    /// noktalar". An empty result is a real and useful answer here.
    public static func weakOnly(
        _ candidates: [WeakPointCandidate],
        outcomes: [ExerciseOutcome],
        now: Date
    ) -> [WeakPointCandidate] {
        let scores = ExercisePracticeWeight.scores(for: outcomes, now: now)
        let weak = candidates.filter { isWeak($0, score: scores[$0.cardId, default: 0]) }
        return rank(weak, outcomes: outcomes, now: now)
    }

    /// Weakest first. Practice history leads because it is the most recent
    /// evidence; FSRS lapses, low confidence and low stability break ties, and
    /// `updatedAt` makes the order total so the same deck always ranks the
    /// same way.
    public static func rank(
        _ candidates: [WeakPointCandidate],
        outcomes: [ExerciseOutcome],
        now: Date
    ) -> [WeakPointCandidate] {
        let scores = ExercisePracticeWeight.scores(for: outcomes, now: now)
        return candidates.sorted { left, right in
            let leftScore = scores[left.cardId, default: 0]
            let rightScore = scores[right.cardId, default: 0]
            if leftScore != rightScore { return leftScore > rightScore }
            if left.lapseCount != right.lapseCount { return left.lapseCount > right.lapseCount }
            if left.lowConfidence != right.lowConfidence { return left.lowConfidence }
            if left.stability != right.stability { return left.stability < right.stability }
            return left.updatedAt < right.updatedAt
        }
    }
}

public enum ExerciseSelection {
    /// Chooses which cards a run of `limit` cards should contain.
    ///
    /// `ranked` callers (Zayıf noktalar) have already ordered the pool by how
    /// much it needs work, so the top of the list is the answer. Everyone else
    /// must be sampled at random: the pool arrives in `createdAt` order, so
    /// taking a prefix would hand out the same newest N cards on every single
    /// run no matter how often "Hızlı 10" is tapped. `ExerciseSession` shuffles
    /// afterwards either way — that only randomises the *order*, which is a
    /// different problem from randomising the *selection*.
    public static func pick(
        from ids: [UUID],
        limit: Int?,
        ranked: Bool,
        using generator: inout some RandomNumberGenerator
    ) -> [UUID] {
        guard let limit, limit > 0, limit < ids.count else { return ids }
        return ranked
            ? Array(ids.prefix(limit))
            : Array(ids.shuffled(using: &generator).prefix(limit))
    }
}
