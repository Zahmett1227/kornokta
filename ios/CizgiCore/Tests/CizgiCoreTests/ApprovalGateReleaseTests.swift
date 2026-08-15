import XCTest
import SwiftData
@testable import CizgiCore

/// Releasing the cards stuck at the removed approval gate (2026-08-15).
///
/// Run against a real in-memory `ModelContainer` rather than plain values, for
/// one specific reason: the caller writes a one-shot "done" flag, so a lookup
/// that matched nothing would not fail loudly — it would mark itself finished
/// and leave the cards stranded for good. The point of these is to prove the
/// lookup actually finds a `needsReview` card through `Card`'s computed
/// `status`/`statusRaw` bridge.
final class ApprovalGateReleaseTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func insert(_ status: CardStatus, into context: ModelContext) -> Card {
        let card = Card(type: .directRecall, front: "Soru", back: "Cevap", status: status)
        context.insert(card)
        return card
    }

    /// The whole point: found through the stored-string bridge, not skipped by it.
    func testAStrandedCardIsActivated() throws {
        let context = try makeContext()
        let card = insert(.needsReview, into: context)

        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 1)
        XCTAssertEqual(card.status, .active)
    }

    /// The owner's deck shape on the day this shipped: 25 waiting, the rest
    /// already active. Only the 25 may move.
    func testOnlyTheWaitingCardsMove() throws {
        let context = try makeContext()
        for _ in 0..<25 { insert(.needsReview, into: context) }
        for _ in 0..<5 { insert(.active, into: context) }

        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 25)
        let all = try context.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(all.count, 30)
        XCTAssertTrue(all.allSatisfy { $0.status == .active })
    }

    /// A suspended card is a decision the owner made, not a card waiting on
    /// one. Un-suspending it here would silently overrule them.
    func testSuspendedAndDraftCardsAreLeftAlone() throws {
        let context = try makeContext()
        let suspended = insert(.suspended, into: context)
        let draft = insert(.draft, into: context)

        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 0)
        XCTAssertEqual(suspended.status, .suspended)
        XCTAssertEqual(draft.status, .draft)
    }

    /// Nothing but `status` moves. These cards have never been reviewed, and a
    /// migration that touched the scheduling fields would be inventing history
    /// for them.
    func testSchedulingAndProvenanceAreUntouched() throws {
        let context = try makeContext()
        let card = insert(.needsReview, into: context)
        let due = card.dueDate
        let created = card.createdAt

        try ApprovalGateRelease.release(in: context)

        XCTAssertEqual(card.dueDate, due)
        XCTAssertEqual(card.createdAt, created)
        XCTAssertEqual(card.reviewCount, 0)
        XCTAssertEqual(card.lapseCount, 0)
        XCTAssertEqual(card.stability, 0)
        XCTAssertTrue(card.reviews.isEmpty)
    }

    /// The App-side flag makes this a once-ever call, but a rolled-back save
    /// means it runs again on the next launch — so it has to be safe to repeat.
    func testRunningTwiceIsANoOpTheSecondTime() throws {
        let context = try makeContext()
        insert(.needsReview, into: context)

        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 1)
        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 0)
    }

    func testAnEmptyDeckIsNotAnError() throws {
        XCTAssertEqual(try ApprovalGateRelease.release(in: try makeContext()), 0)
    }

    /// The restore hole (Codex review, PR #44), reproduced as the sequence that
    /// causes it: a fresh install runs this against an empty store and spends
    /// the App-side one-shot flag on nothing, then a backup taken before any of
    /// this shipped restores cards with their stored `.needsReview` intact. The
    /// release has to still find them when the restore flow calls it again —
    /// otherwise those cards sit outside every review with the flag saying the
    /// work is done.
    func testCardsArrivingAfterAnEarlierRunAreStillReleased() throws {
        let context = try makeContext()
        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 0, "boş destede yapacak iş yok")

        let restored = insert(.needsReview, into: context)
        XCTAssertEqual(try ApprovalGateRelease.release(in: context), 1)
        XCTAssertEqual(restored.status, .active)
    }
}
