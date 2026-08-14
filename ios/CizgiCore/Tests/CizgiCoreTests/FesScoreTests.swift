import XCTest
@testable import CizgiCore

final class FesScoreTests: XCTestCase {

    // MARK: Ağırlıklar ve eşleme

    func testExerciseResultWeights() {
        XCTAssertEqual(FesScore.signal(for: .missed).weight, 2)
        XCTAssertEqual(FesScore.signal(for: .unsure).weight, 1)
        XCTAssertEqual(FesScore.signal(for: .knew).weight, -2)
    }

    func testReviewRatingWeights() {
        XCTAssertEqual(FesScore.signal(for: .again).weight, 2)
        XCTAssertEqual(FesScore.signal(for: .hard).weight, 1)
        XCTAssertEqual(FesScore.signal(for: .good).weight, -2)
        XCTAssertEqual(FesScore.signal(for: .easy).weight, -2)
    }

    func testOnlyWrongAndUnsureAreNegative() {
        XCTAssertTrue(FesScore.Signal.wrong.isNegative)
        XCTAssertTrue(FesScore.Signal.unsure.isNegative)
        XCTAssertFalse(FesScore.Signal.correct.isNegative)
    }

    // MARK: Taban / tavan kırpması

    func testScoreNeverGoesBelowFloor() {
        XCTAssertEqual(FesScore.apply(.correct, to: 0), 0)
        XCTAssertEqual(FesScore.apply(.correct, to: 1), 0)
    }

    func testScoreNeverExceedsCeiling() {
        XCTAssertEqual(FesScore.apply(.wrong, to: 12), 12)
        XCTAssertEqual(FesScore.apply(.wrong, to: 11), 12)
    }

    func testSixConsecutiveCorrectAnswersClearAnyScoreFromTheCeiling() {
        var score = FesScore.ceiling
        for _ in 0..<6 {
            score = FesScore.apply(.correct, to: score)
        }
        XCTAssertEqual(score, FesScore.floor)
    }

    // MARK: Eşik

    func testThresholdBoundary() {
        XCTAssertFalse(FesScore.isFes(score: FesScore.threshold - 1))
        XCTAssertTrue(FesScore.isFes(score: FesScore.threshold))
    }

    func testTwoWrongAnswersCrossTheThreshold() {
        let score = FesScore.replay([.wrong, .wrong])
        XCTAssertEqual(score, 4)
        XCTAssertTrue(FesScore.isFes(score: score))
    }

    func testOneWrongPlusOneUnsureLandsExactlyOnTheThreshold() {
        let score = FesScore.replay([.wrong, .unsure])
        XCTAssertEqual(score, 3)
        XCTAssertTrue(FesScore.isFes(score: score))
    }

    func testASingleWrongAnswerIsNotFes() {
        let score = FesScore.replay([.wrong])
        XCTAssertFalse(FesScore.isFes(score: score))
    }

    // MARK: `replay` sıralama duyarlılığı

    func testTenCorrectThenTwoWrongReadsAsBarelyFesNotDeeplyNegative() {
        // A running score clamped at the floor should treat a long correct
        // streak followed by a couple of misses as a fresh, mild problem —
        // not as "−16", which a lifetime sum would compute.
        let signals = Array(repeating: FesScore.Signal.correct, count: 10) + [.wrong, .wrong]
        let score = FesScore.replay(signals)
        XCTAssertEqual(score, 4)
        XCTAssertTrue(FesScore.isFes(score: score))
    }

    func testOrderMattersScoreIsNotACommutativeSum() {
        // Same multiset of signals, different order → same result here
        // because clamping only bites at the extremes, but the two paths
        // exercise different clamp points and must still agree with a
        // hand-computed running trace, not a naive sum.
        let earlyWrong = FesScore.replay([.wrong, .wrong, .correct, .correct])
        let lateWrong = FesScore.replay([.correct, .correct, .wrong, .wrong])
        XCTAssertEqual(earlyWrong, 0) // 2 → 4 → 2 → 0
        XCTAssertEqual(lateWrong, 4) // 0 → 0 (clamped) → 2 → 4
        XCTAssertNotEqual(earlyWrong, lateWrong)
    }

    func testReplayOfEmptyHistoryIsFloor() {
        XCTAssertEqual(FesScore.replay([]), FesScore.floor)
    }

    // MARK: Kurtarma davranışı

    func testACorrectedCardEventuallyDropsOutOfFes() {
        var score = FesScore.replay([.wrong, .wrong]) // 4, FES
        XCTAssertTrue(FesScore.isFes(score: score))
        score = FesScore.apply(.correct, to: score) // 2
        XCTAssertFalse(FesScore.isFes(score: score))
    }
}
