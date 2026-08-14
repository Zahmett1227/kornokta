import XCTest
@testable import CizgiCore

final class ExerciseBudgetTests: XCTestCase {

    func testCardsBudgetIgnoresPace() {
        XCTAssertEqual(ExerciseBudget.cards(20).limit(secondsPerCard: 12), 20)
        XCTAssertEqual(ExerciseBudget.cards(20).limit(secondsPerCard: 999), 20)
    }

    func testAllBudgetIsUnlimited() {
        XCTAssertNil(ExerciseBudget.all.limit(secondsPerCard: 12))
    }

    func testMinutesBudgetDelegatesToReviewPace() {
        // 10 dk × 60 sn / 12 sn-kart (fallback pace) = 50 kart.
        XCTAssertEqual(
            ExerciseBudget.minutes(10).limit(secondsPerCard: ReviewPace.fallbackSecondsPerCard),
            ReviewPace.cardCount(forMinutes: 10, secondsPerCard: ReviewPace.fallbackSecondsPerCard)
        )
        XCTAssertEqual(ExerciseBudget.minutes(10).limit(secondsPerCard: 12), 50)
    }

    func testMinutesBudgetAdaptsToAFasterMeasuredPace() {
        // Aynı süre bütçesi, daha hızlı bir kullanıcı için daha çok kart demek.
        let slow = ExerciseBudget.minutes(5).limit(secondsPerCard: 30)
        let fast = ExerciseBudget.minutes(5).limit(secondsPerCard: 10)
        XCTAssertEqual(slow, 10)
        XCTAssertEqual(fast, 30)
        XCTAssertLessThan(slow!, fast!)
    }

    func testMinutesBudgetNeverProducesZeroCards() {
        // ReviewPace.cardCount'un kendi tabanı: bütçe hiç boş bir oturum
        // üretmemeli, çok yavaş bir hızda bile.
        XCTAssertEqual(ExerciseBudget.minutes(1).limit(secondsPerCard: 999), 1)
    }

    func testPresetsAreNonEmptyAndAscending() {
        XCTAssertEqual(ExerciseBudget.cardPresets, ExerciseBudget.cardPresets.sorted())
        XCTAssertEqual(ExerciseBudget.minutePresets, ExerciseBudget.minutePresets.sorted())
        XCTAssertFalse(ExerciseBudget.cardPresets.isEmpty)
        XCTAssertFalse(ExerciseBudget.minutePresets.isEmpty)
    }
}
