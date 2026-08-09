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
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }()

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
        scheduler: StubScheduler? = nil
    ) -> EarlyPracticeUpdate {
        EarlyPractice.update(
            result: result,
            state: state ?? self.state(),
            dueDate: due,
            scheduler: scheduler ?? self.scheduler(),
            now: now,
            calendar: calendar
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

    func testSameCalendarDayAsTheRealReviewIsFrozen() {
        let sameDay = calendar.date(byAdding: .hour, value: 3, to: lastReviewed)!
        let update = update(.knew, at: sameDay)
        XCTAssertEqual(update.kind, .sameDayFrozen)
        XCTAssertFalse(update.touchesCard)
    }

    func testMalformedIntervalDoesNothingRatherThanDividingByIt() {
        let broken = SchedulingState(
            stability: 10, difficulty: 5, reviewCount: 3, lapseCount: 0,
            // Reviewed *after* the due date — clock change or hand-edited data.
            lastReviewedAt: due.addingTimeInterval(day)
        )
        let result = EarlyPractice.update(
            result: .missed, state: broken, dueDate: due,
            scheduler: scheduler(), now: due.addingTimeInterval(-1), calendar: calendar
        )
        XCTAssertEqual(result.kind, .none)
    }

    // MARK: Erken doğru — kısmi kredi

    func testEarlyCorrectEarnsAFractionOfTheGoodGain() {
        // 50% of the interval → weight 0.65. Gain over current stability is
        // 18 − 10 = 8 → new stability 10 + 8 × 0.65.
        let update = update(.knew, at: lastReviewed.addingTimeInterval(10 * day))
        XCTAssertEqual(update.kind, .partialCredit)
        XCTAssertEqual(update.stability ?? 0, 10 + 8 * 0.65, accuracy: 0.0001)
        // The due date is never pushed out from practice, and difficulty and
        // the counters stay: this informs the model, it is not a review.
        XCTAssertNil(update.dueDate)
        XCTAssertNil(update.difficulty)
        XCTAssertEqual(update.reviewCountDelta, 0)
        XCTAssertNil(update.lastReviewedAt)
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
    }

    func testSoftLapseNeverPushesAnAlreadyCloseDueDateOut() {
        // A two-day interval, missed at 1.4 days (ratio 0.7, a different
        // calendar day than the review): the card is already due in 0.6 days,
        // *sooner* than the one-day pull-forward — min(due, now+1d) must keep
        // the earlier of the two, or a soft lapse would postpone the review.
        let shortDue = lastReviewed.addingTimeInterval(2 * day)
        let now = lastReviewed.addingTimeInterval(1.4 * day)
        let update = EarlyPractice.update(
            result: .missed, state: state(), dueDate: shortDue,
            scheduler: scheduler(), now: now, calendar: calendar
        )
        XCTAssertEqual(update.kind, .softLapse)
        XCTAssertEqual(update.dueDate, shortDue)
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
        XCTAssertEqual(update.softLapseCountDelta, 0)
    }

    func testThresholdItselfCountsAsReal() {
        // Exactly 75%: the boundary belongs to the real-lapse side.
        let now = lastReviewed.addingTimeInterval(15 * day)
        XCTAssertEqual(update(.missed, at: now).kind, .relearn)
    }
}
