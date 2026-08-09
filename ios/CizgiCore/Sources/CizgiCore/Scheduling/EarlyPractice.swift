import Foundation

/// How an Egzersiz answer is allowed to touch FSRS state (docs/ADR-007).
///
/// Egzersiz began fully FSRS-blind on purpose: a practice walk must not let the
/// user grind a card's interval up, and a self-test taken *before* the card was
/// due must not count as a real lapse. But fully blind had the opposite cost —
/// the more the user practises, the less FSRS knows about what they actually
/// know. This is the guarded bridge between the two, ported from the owner's
/// tusoskop scheduler (`applyEarlyReview`/soft-lapse/same-day rules) and
/// adapted to a real FSRS-6 deck:
///
/// - A **due** card is left alone entirely: grading it is the review session's
///   job, and doing it from Egzersiz would silently drain the review queue.
/// - A card already reviewed **today** is frozen: repeating a card five times
///   in one sitting says nothing about next week.
/// - An **early correct** answer earns partial stability credit — a fraction of
///   what a "Good" review would have added, growing with how close to due the
///   card was. The due date is never pushed out: Egzersiz can only inform the
///   model, never postpone a review.
/// - An **early wrong** answer close to due (≥ 75% of the interval elapsed) is
///   a real lapse and takes the full FSRS "Again" update. Earlier than that it
///   is a *soft* lapse: the card is pulled forward (at most one day away) and
///   `softLapseCount` records the event, but stability, difficulty and the real
///   lapse count stay untouched — failing a self-test taken too soon is noise,
///   not forgetting.
/// - "Kararsızdım" (`unsure`) never touches FSRS; it stays analytics-only.
///
/// `ReviewLog` is never written from here: the review history remains the
/// record of real, scheduled reviews (docs/ADR-007 keeps that half of the old
/// invariant).
public struct EarlyPracticeUpdate: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        /// Nothing to do: `unsure`, a never-reviewed card, or bad interval data.
        case none
        /// The card is due; the review session owns it.
        case leftForReview
        /// Already reviewed this calendar day; schedule frozen.
        case sameDayFrozen
        /// Early correct: partial stability credit, due date untouched.
        case partialCredit
        /// Early wrong, far from due: pulled forward, counted softly.
        case softLapse
        /// Early wrong, close to due: a real FSRS "Again" update.
        case relearn
    }

    public let kind: Kind
    /// Fields that changed; `nil` means "leave the card's value as it is".
    public let stability: Double?
    public let difficulty: Double?
    public let dueDate: Date?
    public let lastReviewedAt: Date?
    public let reviewCountDelta: Int
    public let lapseCountDelta: Int
    public let softLapseCountDelta: Int

    init(
        kind: Kind,
        stability: Double? = nil,
        difficulty: Double? = nil,
        dueDate: Date? = nil,
        lastReviewedAt: Date? = nil,
        reviewCountDelta: Int = 0,
        lapseCountDelta: Int = 0,
        softLapseCountDelta: Int = 0
    ) {
        self.kind = kind
        self.stability = stability
        self.difficulty = difficulty
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
        self.reviewCountDelta = reviewCountDelta
        self.lapseCountDelta = lapseCountDelta
        self.softLapseCountDelta = softLapseCountDelta
    }

    public var touchesCard: Bool {
        stability != nil || difficulty != nil || dueDate != nil || lastReviewedAt != nil
            || reviewCountDelta != 0 || lapseCountDelta != 0 || softLapseCountDelta != 0
    }
}

public enum EarlyPractice {
    /// An early wrong answer at or past this fraction of the scheduled interval
    /// is a real lapse; below it, a soft one. Tusoskop's value, kept as-is.
    public static let realLapseThreshold = 0.75

    /// A soft lapse pulls the card to at most this far away.
    public static let softLapsePullForward: TimeInterval = 86_400

    /// Fraction of a full "Good" review's stability gain an early correct
    /// answer earns, by how much of the scheduled interval had elapsed.
    /// Tusoskop's step function (`getEarlyWeight`), unchanged: recalling a card
    /// five minutes after seeing it proves very little; recalling it at 90% of
    /// its interval proves almost as much as the review itself would have.
    public static func earlyWeight(progressRatio: Double) -> Double {
        switch progressRatio {
        case ..<0.15: return 0.1
        case ..<0.5: return 0.35
        case ..<0.8: return 0.65
        default: return 0.9
        }
    }

    /// Decides what an Egzersiz answer may change. Pure — the caller applies
    /// the returned fields to the card — so the whole policy is testable
    /// without SwiftData or a real clock.
    public static func update(
        result: ExerciseResult,
        state: SchedulingState,
        dueDate: Date,
        scheduler: any ReviewScheduling,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> EarlyPracticeUpdate {
        // Uncertainty is a feeling, not a grade; it feeds the weak-point
        // heuristic through `ExerciseAttempt` and nothing else.
        guard result != .unsure else { return EarlyPracticeUpdate(kind: .none) }

        // A card FSRS has never seen has no interval to be "early" against.
        // Its first grading belongs to the review session.
        guard let lastReviewedAt = state.lastReviewedAt, state.reviewCount > 0 else {
            return EarlyPracticeUpdate(kind: .none)
        }

        // Due (or overdue): the review session's job. Grading it here would
        // drain the review queue through the practice screen.
        guard now < dueDate else { return EarlyPracticeUpdate(kind: .leftForReview) }

        // Same calendar day as the real review: frozen. Without this, a few
        // practice passes on review day would compound partial credit onto an
        // interval that was just set.
        if calendar.isDate(now, inSameDayAs: lastReviewedAt) {
            return EarlyPracticeUpdate(kind: .sameDayFrozen)
        }

        let scheduled = dueDate.timeIntervalSince(lastReviewedAt)
        let elapsed = now.timeIntervalSince(lastReviewedAt)
        // A malformed interval (clock change, hand-edited data) is a reason to
        // do nothing, never to divide by it.
        guard scheduled > 0, elapsed > 0 else { return EarlyPracticeUpdate(kind: .none) }
        let progressRatio = elapsed / scheduled

        switch result {
        case .knew:
            // A fraction of the stability a real "Good" review would have set.
            // Due date and difficulty stay: practice informs the model (the
            // next real review sees a stronger card and schedules further
            // out), but never replaces the review.
            let good = scheduler.schedule(rating: .good, state: state, now: now)
            let gain = max(0, good.stability - state.stability)
            guard gain > 0 else { return EarlyPracticeUpdate(kind: .none) }
            return EarlyPracticeUpdate(
                kind: .partialCredit,
                stability: state.stability + gain * earlyWeight(progressRatio: progressRatio)
            )

        case .missed where progressRatio < realLapseThreshold:
            // Too early to call it forgetting. Pull the card forward so the
            // review session sees it soon, and count the event softly.
            return EarlyPracticeUpdate(
                kind: .softLapse,
                dueDate: min(dueDate, now.addingTimeInterval(softLapsePullForward)),
                softLapseCountDelta: 1
            )

        case .missed:
            // Close enough to due that missing it is real evidence of
            // forgetting: the full FSRS "Again" update, exactly as the review
            // session would apply it.
            let again = scheduler.schedule(rating: .again, state: state, now: now)
            return EarlyPracticeUpdate(
                kind: .relearn,
                stability: again.stability,
                difficulty: again.difficulty,
                dueDate: again.dueDate,
                lastReviewedAt: now,
                reviewCountDelta: 1,
                lapseCountDelta: 1
            )

        case .unsure:
            return EarlyPracticeUpdate(kind: .none)
        }
    }
}
