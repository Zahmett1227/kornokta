import XCTest
@testable import CizgiCore

/// A seeded generator so a shuffle can be asserted at all — the same reason
/// the scheduling tests inject a clock rather than reading `Date.now`.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class ExerciseSessionTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    func testTheSameSeedProducesTheSameOrder() {
        let cards = ids(10)
        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)
        let a = ExerciseSession(cardIds: cards, using: &first)
        let b = ExerciseSession(cardIds: cards, using: &second)
        XCTAssertEqual(a.queue, b.queue)
    }

    func testShufflingKeepsEveryCardExactlyOnce() {
        let cards = ids(20)
        var generator = SeededGenerator(seed: 7)
        let session = ExerciseSession(cardIds: cards, using: &generator)
        XCTAssertEqual(Set(session.queue), Set(cards))
        XCTAssertEqual(session.queue.count, cards.count)
    }

    func testAdvancingWalksToTheEndAndStops() {
        var generator = SeededGenerator(seed: 1)
        var session = ExerciseSession(cardIds: ids(3), using: &generator)

        XCTAssertEqual(session.total, 3)
        XCTAssertEqual(session.completed, 0)
        XCTAssertNotNil(session.current)

        session.advance()
        session.advance()
        XCTAssertEqual(session.completed, 2)
        XCTAssertFalse(session.isFinished)

        session.advance()
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.current)

        // No wrap-around: past the end stays past the end.
        session.advance()
        XCTAssertEqual(session.completed, 3)
        XCTAssertNil(session.current)
    }

    func testRestartReshufflesAndReturnsToTheStart() {
        var generator = SeededGenerator(seed: 3)
        var session = ExerciseSession(cardIds: ids(12), using: &generator)
        let firstOrder = session.queue
        while !session.isFinished { session.advance() }

        var second = SeededGenerator(seed: 99)
        session.restart(using: &second)

        XCTAssertEqual(session.completed, 0)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(Set(session.queue), Set(firstOrder))
        // A second pass in the original order would test recall of the
        // sequence as much as of the cards.
        XCTAssertNotEqual(session.queue, firstOrder)
    }

    func testAnEmptySessionIsImmediatelyFinished() {
        var generator = SeededGenerator(seed: 5)
        let session = ExerciseSession(cardIds: [], using: &generator)
        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.current)
        XCTAssertEqual(session.total, 0)
    }

    func testRemovingADeletedCardKeepsTheCursorOnTheSameCard() {
        var generator = SeededGenerator(seed: 11)
        var session = ExerciseSession(cardIds: ids(5), using: &generator)
        session.advance()
        session.advance()
        let current = session.current

        // A card *behind* the cursor going away must not shift the walk.
        session.remove(session.queue[0])
        XCTAssertEqual(session.current, current)
        XCTAssertEqual(session.total, 4)

        // The current card going away moves the next one into its place.
        let following = session.queue[session.completed + 1]
        session.remove(session.current!)
        XCTAssertEqual(session.current, following)
    }
}
