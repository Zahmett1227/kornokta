import Foundation

public struct SchedulingResult: Sendable, Equatable {
    public let dueDate: Date
    public let stability: Double
    public let difficulty: Double
    public let scheduledDays: Double

    public init(dueDate: Date, stability: Double, difficulty: Double, scheduledDays: Double) {
        self.dueDate = dueDate
        self.stability = stability
        self.difficulty = difficulty
        self.scheduledDays = scheduledDays
    }
}

public struct SchedulingState: Sendable, Equatable {
    public var stability: Double
    public var difficulty: Double
    public var reviewCount: Int
    public var lapseCount: Int
    public var lastReviewedAt: Date?

    public init(
        stability: Double = 0,
        difficulty: Double = 0,
        reviewCount: Int = 0,
        lapseCount: Int = 0,
        lastReviewedAt: Date? = nil
    ) {
        self.stability = stability
        self.difficulty = difficulty
        self.reviewCount = reviewCount
        self.lapseCount = lapseCount
        self.lastReviewedAt = lastReviewedAt
    }
}

/// Spaced-repetition scheduling. Deterministic and offline by contract — the
/// model never decides when a card comes back (ANA-PLAN §0.8, P6, §11.4).
public protocol ReviewScheduling: Sendable {
    func schedule(rating: ReviewRating, state: SchedulingState, now: Date) -> SchedulingResult
}

/// Faz 1 placeholder.
///
/// **This is not FSRS.** ANA-PLAN §18 puts the real algorithm in Faz 4, tested
/// against a reference implementation. This exists only so the review loop can
/// be exercised end to end in Faz 1; it uses plain doubling intervals and makes
/// no claim about retention. `ReviewScheduling` is the seam FSRS drops into
/// without touching the store or the UI.
public struct PlaceholderScheduler: ReviewScheduling {
    public init() {}

    /// Interval in days for a card with no history, by rating.
    static let firstIntervals: [ReviewRating: Double] = [
        .again: 0,        // same session
        .hard: 1,
        .good: 2,
        .easy: 4
    ]

    /// How much an existing interval grows, by rating. `again` resets.
    static let growthFactors: [ReviewRating: Double] = [
        .again: 0,
        .hard: 1.2,
        .good: 2.0,
        .easy: 3.0
    ]

    public func schedule(rating: ReviewRating, state: SchedulingState, now: Date = .now) -> SchedulingResult {
        let previousDays = max(state.stability, 0)
        // Both tables are read here; editing either one changes behaviour,
        // which is the point of having them (they used to be shadowed by
        // hardcoded literals below).
        let first = Self.firstIntervals[rating] ?? 0
        let growth = Self.growthFactors[rating] ?? 0
        let days: Double

        if rating == .again {
            // Back to the start of the ladder, and count the lapse.
            days = 0
        } else if previousDays > 0 {
            days = max(1, previousDays * growth)
        } else {
            days = first
        }

        let cappedDays = min(days, 365)
        // A lapsed card comes back in ten minutes rather than "now", so it does
        // not immediately reappear at the top of the same session.
        let due = cappedDays == 0
            ? now.addingTimeInterval(10 * 60)
            : now.addingTimeInterval(cappedDays * 86_400)

        let difficulty: Double
        switch rating {
        case .again: difficulty = min(state.difficulty + 1, 10)
        case .hard: difficulty = min(state.difficulty + 0.3, 10)
        case .good: difficulty = state.difficulty
        case .easy: difficulty = max(state.difficulty - 0.3, 0)
        }

        return SchedulingResult(
            dueDate: due,
            stability: cappedDays,
            difficulty: difficulty,
            scheduledDays: cappedDays
        )
    }
}

/// Picks what to study now (§18.3).
public enum ReviewSessionPlanner {

    /// Cards due at `now`, ordered oldest-due first, with cards from the same
    /// knowledge unit spread apart so a passage's cards are not asked back to
    /// back (§18.3).
    public static func plan(
        cards: [(id: UUID, dueDate: Date, knowledgeUnitId: UUID?, status: CardStatus)],
        now: Date,
        limit: Int? = nil
    ) -> [UUID] {
        let due = cards
            .filter { $0.status == .active && $0.dueDate <= now }
            .sorted { $0.dueDate < $1.dueDate }

        var byUnit: [UUID?: [UUID]] = [:]
        var unitOrder: [UUID?] = []
        for card in due {
            if byUnit[card.knowledgeUnitId] == nil {
                byUnit[card.knowledgeUnitId] = []
                unitOrder.append(card.knowledgeUnitId)
            }
            byUnit[card.knowledgeUnitId]?.append(card.id)
        }

        // Round-robin across knowledge units.
        var result: [UUID] = []
        var exhausted = false
        var round = 0
        while !exhausted {
            exhausted = true
            for unit in unitOrder {
                guard let cards = byUnit[unit], round < cards.count else { continue }
                result.append(cards[round])
                exhausted = false
            }
            round += 1
        }

        if let limit { return Array(result.prefix(limit)) }
        return result
    }
}
