import XCTest
@testable import CizgiCore

final class PlaceholderSchedulerTests: XCTestCase {
    let scheduler = PlaceholderScheduler()
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFirstReviewIntervalsGrowWithTheGrade() {
        let fresh = SchedulingState()
        let hard = scheduler.schedule(rating: .hard, state: fresh, now: now)
        let good = scheduler.schedule(rating: .good, state: fresh, now: now)
        let easy = scheduler.schedule(rating: .easy, state: fresh, now: now)

        XCTAssertLessThan(hard.scheduledDays, good.scheduledDays)
        XCTAssertLessThan(good.scheduledDays, easy.scheduledDays)
    }

    func testAgainComesBackWithinTheSessionNotImmediately() {
        let result = scheduler.schedule(rating: .again, state: SchedulingState(stability: 30), now: now)
        XCTAssertEqual(result.scheduledDays, 0)
        // Ten minutes out, so it does not reappear at the top of the same list.
        XCTAssertGreaterThan(result.dueDate, now)
        XCTAssertLessThan(result.dueDate, now.addingTimeInterval(3600))
    }

    func testIntervalsAreCapped() {
        let mature = SchedulingState(stability: 300)
        let result = scheduler.schedule(rating: .easy, state: mature, now: now)
        XCTAssertLessThanOrEqual(result.scheduledDays, 365)
    }

    func testDifficultyMovesWithTheGrade() {
        let state = SchedulingState(difficulty: 5)
        XCTAssertGreaterThan(scheduler.schedule(rating: .again, state: state, now: now).difficulty, 5)
        XCTAssertEqual(scheduler.schedule(rating: .good, state: state, now: now).difficulty, 5)
        XCTAssertLessThan(scheduler.schedule(rating: .easy, state: state, now: now).difficulty, 5)
    }

    func testDifficultyStaysInRange() {
        let low = SchedulingState(difficulty: 0)
        XCTAssertGreaterThanOrEqual(scheduler.schedule(rating: .easy, state: low, now: now).difficulty, 0)
        let high = SchedulingState(difficulty: 10)
        XCTAssertLessThanOrEqual(scheduler.schedule(rating: .again, state: high, now: now).difficulty, 10)
    }

    func testSchedulingIsDeterministic() {
        // §0.8/P6: scheduling is code, not a model, so the same input must
        // always give the same date.
        let state = SchedulingState(stability: 7, difficulty: 3)
        let a = scheduler.schedule(rating: .good, state: state, now: now)
        let b = scheduler.schedule(rating: .good, state: state, now: now)
        XCTAssertEqual(a, b)
    }
}

final class ReviewSessionPlannerTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyDueActiveCardsAreIncluded() {
        let unitA = UUID()
        let cards: [(id: UUID, dueDate: Date, knowledgeUnitId: UUID?, status: CardStatus)] = [
            (UUID(), now.addingTimeInterval(-100), unitA, .active),
            (UUID(), now.addingTimeInterval(3600), unitA, .active),   // not due
            (UUID(), now.addingTimeInterval(-100), unitA, .suspended) // suspended
        ]
        let plan = ReviewSessionPlanner.plan(cards: cards, now: now)
        XCTAssertEqual(plan.count, 1)
    }

    func testSuspendedCardsNeverEnterTheSession() {
        // §18.3: askıya alınmış kartlar planlamaya girmez.
        let cards: [(id: UUID, dueDate: Date, knowledgeUnitId: UUID?, status: CardStatus)] =
            [(UUID(), now.addingTimeInterval(-1), UUID(), .suspended)]
        XCTAssertTrue(ReviewSessionPlanner.plan(cards: cards, now: now).isEmpty)
    }

    func testCardsFromOneUnitAreNotAskedBackToBack() {
        // §18.3: aynı bilgi biriminin kartları arka arkaya yığılmamalı.
        let unitA = UUID(), unitB = UUID()
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        let cards: [(id: UUID, dueDate: Date, knowledgeUnitId: UUID?, status: CardStatus)] = [
            (a1, now.addingTimeInterval(-300), unitA, .active),
            (a2, now.addingTimeInterval(-200), unitA, .active),
            (b1, now.addingTimeInterval(-100), unitB, .active)
        ]
        let plan = ReviewSessionPlanner.plan(cards: cards, now: now)
        XCTAssertEqual(plan, [a1, b1, a2])
    }

    func testLimitTrimsTheSession() {
        let unit = UUID()
        let cards = (0..<10).map {
            (id: UUID(), dueDate: now.addingTimeInterval(Double(-$0)), knowledgeUnitId: unit, status: CardStatus.active)
        }
        XCTAssertEqual(ReviewSessionPlanner.plan(cards: cards, now: now, limit: 3).count, 3)
    }

    func testEmptyInputGivesEmptyPlan() {
        XCTAssertTrue(ReviewSessionPlanner.plan(cards: [], now: now).isEmpty)
    }
}
