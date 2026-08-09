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
/// - A card within **one day of its real review** is frozen: recalling a card
///   hours after reviewing it says nothing about next week. Continuous
///   24-hour window, not a calendar-day check — a calendar boundary shifts
///   with the device's time zone, which is exactly what §18.1 forbids
///   (`FSRSScheduler`'s own same-day semantics are continuous for the same
///   reason).
/// - A card within **one day of its last FSRS-touching practice** is frozen
///   too (`Card.lastPracticedAt`). Without this, running "Hızlı 10" three
///   times in one evening would compound partial credit pass after pass —
///   the grind-the-interval-up behaviour Egzersiz exists to prevent. This is
///   also what keeps a soft lapse's pulled-forward due date from feeding the
///   next answer's progress ratio: within the window everything is frozen,
///   and past it the pulled-forward card is due and belongs to the review
///   session anyway.
/// - An **early correct** answer earns partial stability credit — a fraction of
///   what a "Good" review would have added, growing with how close to due the
///   card was. The due date is never pushed out: Egzersiz can only inform the
///   model, never postpone a review. (Credit *can* accrue across days — a card
///   practised correctly on several different days earns several weighted
///   gains — which is accepted: each is at least a day apart and mirrors real
///   recall evidence, and the freeze above caps it at one per day.)
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
        /// Within a day of the real review; schedule frozen.
        case reviewFrozen
        /// Within a day of the last FSRS-touching practice; frozen so repeated
        /// same-evening passes cannot compound credit or reclassify a miss.
        case practiceFrozen
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
    /// Set on every FSRS-touching outcome; it is what arms `practiceFrozen`
    /// for the next day.
    public let lastPracticedAt: Date?
    public let reviewCountDelta: Int
    public let lapseCountDelta: Int
    public let softLapseCountDelta: Int

    init(
        kind: Kind,
        stability: Double? = nil,
        difficulty: Double? = nil,
        dueDate: Date? = nil,
        lastReviewedAt: Date? = nil,
        lastPracticedAt: Date? = nil,
        reviewCountDelta: Int = 0,
        lapseCountDelta: Int = 0,
        softLapseCountDelta: Int = 0
    ) {
        self.kind = kind
        self.stability = stability
        self.difficulty = difficulty
        self.dueDate = dueDate
        self.lastReviewedAt = lastReviewedAt
        self.lastPracticedAt = lastPracticedAt
        self.reviewCountDelta = reviewCountDelta
        self.lapseCountDelta = lapseCountDelta
        self.softLapseCountDelta = softLapseCountDelta
    }

    public var touchesCard: Bool {
        stability != nil || difficulty != nil || dueDate != nil || lastReviewedAt != nil
            || lastPracticedAt != nil
            || reviewCountDelta != 0 || lapseCountDelta != 0 || softLapseCountDelta != 0
    }
}

public enum EarlyPractice {
    /// An early wrong answer at or past this fraction of the scheduled interval
    /// is a real lapse; below it, a soft one. Tusoskop's value, kept as-is.
    public static let realLapseThreshold = 0.75

    /// A soft lapse pulls the card to at most this far away.
    public static let softLapsePullForward: TimeInterval = 86_400

    /// Continuous 24-hour freeze after a real review and after any
    /// FSRS-touching practice. Continuous on purpose (§18.1): a calendar-day
    /// check shifts with the device's time zone and would unfreeze a card 20
    /// minutes after a 23:50 review.
    public static let freezeWindow: TimeInterval = 86_400

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
        lastPracticedAt: Date?,
        scheduler: any ReviewScheduling,
        now: Date = .now
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
        // drain the review queue through the practice screen. Checked before
        // the freezes so a soft lapse's pulled-forward card lands here, never
        // back in the ratio maths below.
        guard now < dueDate else { return EarlyPracticeUpdate(kind: .leftForReview) }

        let elapsed = now.timeIntervalSince(lastReviewedAt)
        // A malformed interval (clock change, hand-edited data) is a reason to
        // do nothing, never to compute with it.
        guard elapsed > 0 else { return EarlyPracticeUpdate(kind: .none) }

        // Within a day of the real review: frozen. Continuous window, not a
        // calendar-day check — see `freezeWindow`.
        if elapsed < freezeWindow {
            return EarlyPracticeUpdate(kind: .reviewFrozen)
        }

        // Within a day of the last FSRS-touching practice: frozen. This is
        // what stops repeated same-evening passes from compounding credit,
        // and what keeps a soft lapse's mutated due date out of the next
        // answer's progress ratio. A negative interval (clock skew) freezes
        // too — conservative on purpose.
        if let practiced = lastPracticedAt, now.timeIntervalSince(practiced) < freezeWindow {
            return EarlyPracticeUpdate(kind: .practiceFrozen)
        }

        let scheduled = dueDate.timeIntervalSince(lastReviewedAt)
        guard scheduled > 0 else { return EarlyPracticeUpdate(kind: .none) }
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
                stability: state.stability + gain * earlyWeight(progressRatio: progressRatio),
                lastPracticedAt: now
            )

        case .missed where progressRatio < realLapseThreshold:
            // Too early to call it forgetting. Pull the card forward so the
            // review session sees it soon, and count the event softly.
            return EarlyPracticeUpdate(
                kind: .softLapse,
                dueDate: min(dueDate, now.addingTimeInterval(softLapsePullForward)),
                lastPracticedAt: now,
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
                lastPracticedAt: now,
                reviewCountDelta: 1,
                lapseCountDelta: 1
            )

        case .unsure:
            return EarlyPracticeUpdate(kind: .none)
        }
    }
}
