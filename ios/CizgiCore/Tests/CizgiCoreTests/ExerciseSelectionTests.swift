import XCTest
@testable import CizgiCore

/// Deterministic draws, so "two different seeds pick different cards" is a
/// fact about the selection rule and not about luck on the day.
private struct SeededSelectionGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

final class ExerciseSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    private func candidate(
        _ id: UUID,
        lapses: Int = 0,
        lowConfidence: Bool = false,
        stability: Double = 10,
        updatedAt: Date? = nil
    ) -> WeakPointCandidate {
        WeakPointCandidate(
            cardId: id,
            lapseCount: lapses,
            lowConfidence: lowConfidence,
            stability: stability,
            updatedAt: updatedAt ?? now
        )
    }

    private func outcome(_ id: UUID, _ result: ExerciseResult, daysAgo: Double) -> ExerciseOutcome {
        ExerciseOutcome(
            cardId: id,
            result: result,
            answeredAt: now.addingTimeInterval(-daysAgo * 24 * 3600)
        )
    }

    // MARK: Selection

    /// The pool arrives newest-first, so a prefix would hand out the same ten
    /// cards for ever. Two draws from a large pool must not be identical.
    func testUnrankedSelectionSamplesTheWholePoolRatherThanItsHead() {
        let pool = ids(200)
        var first = SeededSelectionGenerator(seed: 1)
        var second = SeededSelectionGenerator(seed: 2)

        let a = ExerciseSelection.pick(from: pool, limit: 10, ranked: false, using: &first)
        let b = ExerciseSelection.pick(from: pool, limit: 10, ranked: false, using: &second)

        XCTAssertEqual(a.count, 10)
        XCTAssertEqual(b.count, 10)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, Array(pool.prefix(10)))
        XCTAssertTrue(a.allSatisfy(pool.contains))
        XCTAssertEqual(Set(a).count, 10, "aynı kart iki kez seçilmemeli")
    }

    /// Zayıf noktalar has already ordered the pool by need, so its top N is the
    /// answer and must survive verbatim.
    func testRankedSelectionKeepsTheTopOfTheList() {
        let pool = ids(50)
        var generator = SeededSelectionGenerator(seed: 3)

        let picked = ExerciseSelection.pick(from: pool, limit: 10, ranked: true, using: &generator)

        XCTAssertEqual(picked, Array(pool.prefix(10)))
    }

    func testNoLimitOrOversizedLimitReturnsTheWholePool() {
        let pool = ids(4)
        var generator = SeededSelectionGenerator(seed: 4)

        XCTAssertEqual(ExerciseSelection.pick(from: pool, limit: nil, ranked: false, using: &generator), pool)
        XCTAssertEqual(ExerciseSelection.pick(from: pool, limit: 9, ranked: false, using: &generator), pool)
        XCTAssertEqual(ExerciseSelection.pick(from: pool, limit: 0, ranked: false, using: &generator), pool)
    }

    // MARK: Practice weight

    func testMissWeighsMoreThanUnsureAndKnowingRemovesWeight() {
        let missed = UUID(), unsure = UUID(), knew = UUID()
        let scores = ExercisePracticeWeight.scores(
            for: [
                outcome(missed, .missed, daysAgo: 0),
                outcome(unsure, .unsure, daysAgo: 0),
                outcome(knew, .knew, daysAgo: 0),
            ],
            now: now
        )

        XCTAssertEqual(scores[missed] ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(scores[unsure] ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(scores[knew] ?? 0, -2, accuracy: 0.001)
    }

    func testAttemptWeightHalvesEveryHalfLife() {
        let card = UUID()
        let scores = ExercisePracticeWeight.scores(for: [outcome(card, .missed, daysAgo: 7)], now: now)

        XCTAssertEqual(scores[card] ?? 0, 1.5, accuracy: 0.001)
    }

    func testAttemptsOlderThanTheWindowAreIgnored() {
        let card = UUID()
        let scores = ExercisePracticeWeight.scores(for: [outcome(card, .missed, daysAgo: 31)], now: now)

        XCTAssertNil(scores[card])
    }

    /// The regression this whole file exists for: under the old flat +3 rule a
    /// card missed once could never leave the weak list, however often it was
    /// answered correctly afterwards.
    func testRelearnedCardFallsBelowAnUntouchedOne() {
        let relearned = UUID(), untouched = UUID()
        let ranked = WeakPointRanking.rank(
            [candidate(relearned), candidate(untouched)],
            outcomes: [
                outcome(relearned, .missed, daysAgo: 20),
                outcome(relearned, .knew, daysAgo: 2),
                outcome(relearned, .knew, daysAgo: 1),
            ],
            now: now
        )

        XCTAssertEqual(ranked.map(\.cardId), [untouched, relearned])
    }

    func testFreshMissOutranksAStaleOne() {
        let fresh = UUID(), stale = UUID()
        let ranked = WeakPointRanking.rank(
            [candidate(stale), candidate(fresh)],
            outcomes: [outcome(stale, .missed, daysAgo: 21), outcome(fresh, .missed, daysAgo: 1)],
            now: now
        )

        XCTAssertEqual(ranked.map(\.cardId), [fresh, stale])
    }

    /// A backup restored across a clock change can stamp answers in the future;
    /// they must not outweigh everything else.
    func testFutureDatedAttemptIsTreatedAsFreshRatherThanAmplified() {
        let card = UUID()
        let scores = ExercisePracticeWeight.scores(for: [outcome(card, .missed, daysAgo: -30)], now: now)

        XCTAssertEqual(scores[card] ?? 0, 3, accuracy: 0.001)
    }

    // MARK: Ranking fallbacks

    func testWithoutPracticeHistoryFsrsSignalsDecideTheOrder() {
        let lapsed = UUID(), unsureCard = UUID(), fragile = UUID(), healthy = UUID()
        let ranked = WeakPointRanking.rank(
            [
                candidate(healthy, stability: 90),
                candidate(fragile, stability: 1),
                candidate(unsureCard, lowConfidence: true, stability: 50),
                candidate(lapsed, lapses: 4, stability: 80),
            ],
            outcomes: [],
            now: now
        )

        XCTAssertEqual(ranked.map(\.cardId), [lapsed, unsureCard, fragile, healthy])
    }
}
