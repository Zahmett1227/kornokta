import XCTest
@testable import CizgiCore

/// A scheduler whose answers are canned per rating, so every assertion is
/// about `EarlyPractice`'s policy and none about FSRS arithmetic (the real
/// scheduler has its own reference-locked tests).
private struct StubScheduler: ReviewScheduling {
    var byRating: [ReviewRating: SchedulingResult]

    func schedule(rating: ReviewRating, state: SchedulingState, now: Date) -> SchedulingResult {
        byRating[rating] ?? SchedulingResult(
            dueDate: now, stability: state.stability, difficulty: state.difficulty, scheduledDays: 0
        )
    }
}

final class EarlyPracticeTests: XCTestCase {
    private let day: TimeInterval = 86_400
    /// Reviewed 10 days ago, due 10 days from now → a 20-day interval at 50%.
    private var lastReviewed: Date { Date(timeIntervalSince1970: 1_700_000_000) }
    private var due: Date { lastReviewed.addingTimeInterval(20 * day) }

    private func state(reviewCount: Int = 3) -> SchedulingState {
        SchedulingState(
            stability: 10,
            difficulty: 5,
            reviewCount: reviewCount,
            lapseCount: 1,
            lastReviewedAt: reviewCount > 0 ? lastReviewed : nil
        )
    }

    private func scheduler(goodStability: Double = 18) -> StubScheduler {
        StubScheduler(byRating: [
            .good: SchedulingResult(dueDate: due, stability: goodStability, difficulty: 5, scheduledDays: 20),
            .again: SchedulingResult(
                dueDate: lastReviewed.addingTimeInterval(19 * day + 600),
                stability: 3,
                difficulty: 6,
                scheduledDays: 0
            ),
        ])
    }

    private func update(
        _ result: ExerciseResult,
        at now: Date,
        state: SchedulingState? = nil,
        dueDate: Date? = nil,
        lastPracticedAt: Date? = nil,
        scheduler: StubScheduler? = nil
    ) -> EarlyPracticeUpdate {
        EarlyPractice.update(
            result: result,
            state: state ?? self.state(),
            dueDate: dueDate ?? due,
            lastPracticedAt: lastPracticedAt,
            scheduler: scheduler ?? self.scheduler(),
            now: now
        )
    }

    // MARK: Kapı koşulları

    func testUnsureNeverTouchesTheCard() {
        let update = update(.unsure, at: lastReviewed.addingTimeInterval(10 * day))
        XCTAssertEqual(update.kind, .none)
        XCTAssertFalse(update.touchesCard)
    }

    func testNeverReviewedCardIsLeftForItsFirstRealReview() {
        let update = update(.knew, at: lastReviewed.addingTimeInterval(10 * day), state: state(reviewCount: 0))
        XCTAssertEqual(update.kind, .none)
        XCTAssertFalse(update.touchesCard)
    }

    func testDueCardBelongsToTheReviewSession() {
        // Grading due cards from Egzersiz would drain the review queue through
        // the practice screen.
        let update = update(.missed, at: due.addingTimeInterval(1))
        XCTAssertEqual(update.kind, .leftForReview)
        XCTAssertFalse(update.touchesCard)
    }

    func testWithinADayOfTheRealReviewIsFrozen() {
        let update = update(.knew, at: lastReviewed.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(update.kind, .reviewFrozen)
        XCTAssertFalse(update.touchesCard)
    }

    func testTheReviewFreezeIsAContinuousDayNotACalendarDay() {
        // A 23:50 review followed by a 00:10 practice is 20 minutes of
        // "retention" — a calendar-day check would unfreeze it (§18.1's
        // timezone objection); the continuous window must not.
        XCTAssertEqual(update(.knew, at: lastReviewed.addingTimeInterval(20 * 3_600)).kind, .reviewFrozen)
        // And a genuinely next-day practice (25 h) is allowed through.
        XCTAssertEqual(update(.knew, at: lastReviewed.addingTimeInterval(25 * 3_600)).kind, .partialCredit)
    }

    func testWithinADayOfTheLastPracticeIsFrozen() {
        // Running "Hızlı 10" three times in one evening must not compound
        // partial credit: after the first FSRS-touching pass, the card is
        // frozen for a day.
        let now = lastReviewed.addingTimeInterval(10 * day)
        let update = update(.knew, at: now, lastPracticedAt: now.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(update.kind, .practiceFrozen)
        XCTAssertFalse(update.touchesCard)
    }

    func testPracticeAgainAfterADayEarnsCreditAgain() {
        let now = lastReviewed.addingTimeInterval(10 * day)
        let update = update(.knew, at: now, lastPracticedAt: now.addingTimeInterval(-25 * 3_600))
        XCTAssertEqual(update.kind, .partialCredit)
    }

    func testMalformedIntervalDoesNothingRatherThanDividingByIt() {
        let broken = SchedulingState(
            stability: 10, difficulty: 5, reviewCount: 3, lapseCount: 0,
            // Reviewed *after* "now" — clock change or hand-edited data.
            lastReviewedAt: due.addingTimeInterval(-1)
        )
        let result = update(.missed, at: due.addingTimeInterval(-2), state: broken)
        XCTAssertEqual(result.kind, .none)
    }

    // MARK: Erken doğru — kısmi kredi

    func testEarlyCorrectEarnsAFractionOfTheGoodGain() {
        // 50% of the interval → weight 0.65. Gain over current stability is
        // 18 − 10 = 8 → new stability 10 + 8 × 0.65.
        let now = lastReviewed.addingTimeInterval(10 * day)
        let update = update(.knew, at: now)
        XCTAssertEqual(update.kind, .partialCredit)
        XCTAssertEqual(update.stability ?? 0, 10 + 8 * 0.65, accuracy: 0.0001)
        // The due date is never pushed out from practice, and difficulty and
        // the counters stay: this informs the model, it is not a review.
        XCTAssertNil(update.dueDate)
        XCTAssertNil(update.difficulty)
        XCTAssertEqual(update.reviewCountDelta, 0)
        XCTAssertNil(update.lastReviewedAt)
        // Arms the practice freeze for the next day.
        XCTAssertEqual(update.lastPracticedAt, now)
    }

    func testTheEarlierTheAnswerTheSmallerTheCredit() {
        // Tusoskop's step function, pinned at each band edge's inside.
        XCTAssertEqual(EarlyPractice.earlyWeight(progressRatio: 0.05), 0.1)
        XCTAssertEqual(EarlyPractice.earlyWeight(progressRatio: 0.3), 0.35)
        XCTAssertEqual(EarlyPractice.earlyWeight(progressRatio: 0.6), 0.65)
        XCTAssertEqual(EarlyPractice.earlyWeight(progressRatio: 0.9), 0.9)
    }

    func testNoCreditWhenTheSchedulerWouldNotHaveGainedEither() {
        // A stub whose "good" stability is *below* the current one: the gain
        // clamps to zero and the card is left alone instead of being weakened.
        let update = update(
            .knew,
            at: lastReviewed.addingTimeInterval(10 * day),
            scheduler: scheduler(goodStability: 4)
        )
        XCTAssertEqual(update.kind, .none)
        XCTAssertFalse(update.touchesCard)
    }

    // MARK: Erken yanlış — soft lapse

    func testEarlyMissIsASoftLapseNotARealOne() {
        // 25% of the interval: far too early for the miss to mean forgetting.
        let now = lastReviewed.addingTimeInterval(5 * day)
        let update = update(.missed, at: now)
        XCTAssertEqual(update.kind, .softLapse)
        XCTAssertEqual(update.softLapseCountDelta, 1)
        XCTAssertEqual(update.lapseCountDelta, 0)
        // Pulled forward to tomorrow, but stability/difficulty untouched.
        XCTAssertEqual(update.dueDate, now.addingTimeInterval(day))
        XCTAssertNil(update.stability)
        XCTAssertNil(update.difficulty)
        XCTAssertEqual(update.lastPracticedAt, now)
    }

    func testSoftLapseNeverPushesAnAlreadyCloseDueDateOut() {
        // A four-day interval, missed at 2.8 days (ratio 0.7): the card is
        // already due in 1.2 days... use a due date *sooner* than now+1d to
        // pin min(due, now+1d) keeping the earlier of the two: interval 40 h,
        // missed at 26 h (ratio 0.65), due in 14 h < 24 h.
        let shortDue = lastReviewed.addingTimeInterval(40 * 3_600)
        let now = lastReviewed.addingTimeInterval(26 * 3_600)
        let update = update(.missed, at: now, dueDate: shortDue)
        XCTAssertEqual(update.kind, .softLapse)
        XCTAssertEqual(update.dueDate, shortDue)
    }

    func testAfterASoftLapseTheCardCannotBeReclassifiedByASecondMiss() {
        // The soft lapse pulled the due date to now+1d. A second miss the same
        // evening must not recompute the progress ratio against that mutated
        // due date and escalate to a real lapse (review of PR #36): within the
        // freeze window it is frozen, and past the window the card is due.
        let firstMissAt = lastReviewed.addingTimeInterval(10 * day)
        let first = update(.missed, at: firstMissAt)
        XCTAssertEqual(first.kind, .softLapse)
        let pulledDue = first.dueDate ?? due

        // Same evening, 3 h later: frozen.
        let secondSameEvening = update(
            .missed,
            at: firstMissAt.addingTimeInterval(3 * 3_600),
            dueDate: pulledDue,
            lastPracticedAt: first.lastPracticedAt
        )
        XCTAssertEqual(secondSameEvening.kind, .practiceFrozen)
        XCTAssertFalse(secondSameEvening.touchesCard)

        // 25 h later: the pulled-forward due date (now+24 h) has passed, so
        // the card belongs to the review session — still no ratio maths.
        let nextDay = update(
            .missed,
            at: firstMissAt.addingTimeInterval(25 * 3_600),
            dueDate: pulledDue,
            lastPracticedAt: first.lastPracticedAt
        )
        XCTAssertEqual(nextDay.kind, .leftForReview)
    }

    // MARK: Vadeye yakın yanlış — gerçek lapse

    func testMissCloseToDueIsARealRelearn() {
        // 95% of the interval elapsed: missing now is real evidence of
        // forgetting, so the full FSRS "Again" update applies.
        let now = lastReviewed.addingTimeInterval(19 * day)
        let update = update(.missed, at: now)
        XCTAssertEqual(update.kind, .relearn)
        XCTAssertEqual(update.stability, 3)
        XCTAssertEqual(update.difficulty, 6)
        XCTAssertEqual(update.dueDate, lastReviewed.addingTimeInterval(19 * day + 600))
        XCTAssertEqual(update.lapseCountDelta, 1)
        XCTAssertEqual(update.reviewCountDelta, 1)
        XCTAssertEqual(update.lastReviewedAt, now)
        XCTAssertEqual(update.lastPracticedAt, now)
        XCTAssertEqual(update.softLapseCountDelta, 0)
    }

    func testThresholdItselfCountsAsReal() {
        // Exactly 75%: the boundary belongs to the real-lapse side.
        let now = lastReviewed.addingTimeInterval(15 * day)
        XCTAssertEqual(update(.missed, at: now).kind, .relearn)
    }
}
