import XCTest
import SwiftData
@testable import CizgiCore

/// `FesScore.record` — the single live FES writer shared by Tekrar, Egzersiz
/// and (next) the Çıkmış bridge.
///
/// Against a real in-memory `Card` rather than plain integers: what these pin
/// is exactly the three fields the two old copies wrote by hand, so a copy
/// that forgot one (the `fesInitializedAt` line is the one Codex caught in
/// PR #41) would fail here instead of in a restored backup.
final class FesScoreRecordTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func makeCard(score: Int = 0) throws -> (Card, ModelContext) {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let card = Card(type: .directRecall, front: "Soru", back: "Cevap", status: .active)
        card.fesScore = score
        context.insert(card)
        return (card, context)
    }

    func testWrongRaisesTheScoreAndCountsAsNegative() throws {
        let (card, _) = try makeCard()
        FesScore.record(.wrong, on: card, at: now)
        XCTAssertEqual(card.fesScore, 2)
        XCTAssertEqual(card.fesNegativeCount, 1)
    }

    func testUnsureCountsAsNegativeToo() throws {
        let (card, _) = try makeCard()
        FesScore.record(.unsure, on: card, at: now)
        XCTAssertEqual(card.fesScore, 1)
        XCTAssertEqual(card.fesNegativeCount, 1)
    }

    /// A correct answer lowers the score but never the lifetime tally.
    func testCorrectLowersTheScoreAndLeavesTheTally() throws {
        let (card, _) = try makeCard(score: 5)
        card.fesNegativeCount = 3
        FesScore.record(.correct, on: card, at: now)
        XCTAssertEqual(card.fesScore, 3)
        XCTAssertEqual(card.fesNegativeCount, 3)
    }

    /// The clamp is `apply`'s, not re-implemented here.
    func testScoreStaysInsideItsBounds() throws {
        let (high, _) = try makeCard(score: FesScore.ceiling)
        FesScore.record(.wrong, on: high, at: now)
        XCTAssertEqual(high.fesScore, FesScore.ceiling)

        let (low, _) = try makeCard(score: FesScore.floor)
        FesScore.record(.correct, on: low, at: now)
        XCTAssertEqual(low.fesScore, FesScore.floor)
    }

    /// Every live answer marks the score as authoritative, whichever way it
    /// went — otherwise a backup taken before the next launch's backfill
    /// replays an empty history and zeroes a real score (PR #41).
    func testEveryAnswerStampsTheInitializationDate() throws {
        for signal in [FesScore.Signal.wrong, .unsure, .correct] {
            let (card, _) = try makeCard()
            XCTAssertNil(card.fesInitializedAt)
            FesScore.record(signal, on: card, at: now)
            XCTAssertEqual(card.fesInitializedAt, now)
        }
    }

    func testTransitionReportsCrossingTheThresholdUpward() throws {
        let (card, _) = try makeCard(score: FesScore.threshold - 1)
        let transition = FesScore.record(.wrong, on: card, at: now)
        XCTAssertTrue(transition.entered)
        XCTAssertFalse(transition.left)
    }

    func testTransitionReportsCrossingTheThresholdDownward() throws {
        let (card, _) = try makeCard(score: FesScore.threshold)
        let transition = FesScore.record(.correct, on: card, at: now)
        XCTAssertTrue(transition.left)
        XCTAssertFalse(transition.entered)
    }

    /// Staying on one side is not a crossing, in either direction.
    func testTransitionIsQuietWhenNothingIsCrossed() throws {
        let (above, _) = try makeCard(score: FesScore.threshold + 4)
        let stayedIn = FesScore.record(.correct, on: above, at: now)
        XCTAssertEqual(stayedIn, FesScore.Transition(wasFes: true, isFes: true))
        XCTAssertFalse(stayedIn.entered || stayedIn.left)

        let (below, _) = try makeCard()
        let stayedOut = FesScore.record(.unsure, on: below, at: now)
        XCTAssertEqual(stayedOut, FesScore.Transition(wasFes: false, isFes: false))
    }
}
