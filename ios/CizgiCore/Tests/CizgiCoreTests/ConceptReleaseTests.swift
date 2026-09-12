import XCTest
import SwiftData
@testable import CizgiCore

/// Letting queued concept cards into the deck in batches.
///
/// The properties worth locking are the ones that would be invisible on a real
/// 3.000-card pack: that a batch never arrives as half a concept, that the order
/// is the pack's and not the database's, and that pressing the button twice in a
/// row does not reset the schedule of cards it already released.
final class ConceptReleaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// One concept with `cards` queued cards, carrying `slug` as its first tag
    /// the way `ConceptPackImporter` writes it.
    @discardableResult
    private func insertConcept(
        slug: String,
        cards: Int,
        into context: ModelContext,
        status: CardStatus = .queued
    ) -> (unit: KnowledgeUnit, cards: [Card]) {
        let unit = KnowledgeUnit(canonicalClaim: slug, tags: [slug, "kavram-paketi"])
        context.insert(unit)
        let made = (0..<cards).map { index -> Card in
            let card = Card(
                type: .directRecall,
                front: "\(slug) soru \(index)",
                back: "cevap",
                status: status,
                createdAt: now,
                dueDate: now,
                collection: .concept
            )
            card.knowledgeUnit = unit
            context.insert(card)
            return card
        }
        return (unit, made)
    }

    // MARK: - Selection

    func testABatchNeverArrivesAsHalfAConcept() throws {
        let context = try makeContext()
        insertConcept(slug: "km-001", cards: 6, into: context)
        insertConcept(slug: "km-002", cards: 7, into: context)

        let all = try context.fetch(FetchDescriptor<Card>())
        let ids = ConceptRelease.plan(ConceptRelease.candidates(in: all), target: 10)

        // 6 is short of 10 so the second concept comes too — whole, not clipped
        // to four cards. Meeting four of a concept's seven cards teaches the
        // fragment and leaves three to arrive later as if they were new.
        XCTAssertEqual(ids.count, 13)
    }

    func testTheTargetIsAFloorNotACeiling() throws {
        let context = try makeContext()
        insertConcept(slug: "km-001", cards: 9, into: context)

        let all = try context.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(ConceptRelease.plan(ConceptRelease.candidates(in: all), target: 1).count, 9)
    }

    /// The ordering is the pack's, which is the book's. Inserted out of order on
    /// purpose: a selector that leaned on insertion order would pass a test
    /// whose fixtures happened to be built in slug order.
    func testConceptsComeOutInPackOrderNotInsertionOrder() throws {
        let context = try makeContext()
        insertConcept(slug: "km-030", cards: 2, into: context)
        insertConcept(slug: "km-010", cards: 2, into: context)
        insertConcept(slug: "km-020", cards: 2, into: context)

        let all = try context.fetch(FetchDescriptor<Card>())
        let ids = ConceptRelease.plan(ConceptRelease.candidates(in: all), target: 3)
        let released = Set(ids)
        let fronts = all.filter { released.contains($0.id) }.map(\.front)

        XCTAssertTrue(fronts.allSatisfy { $0.hasPrefix("km-010") || $0.hasPrefix("km-020") },
                      "km-030 sırada en sonda; önce açılmamalı: \(fronts)")
    }

    func testAlreadyActiveCardsAreNotCandidates() throws {
        let context = try makeContext()
        insertConcept(slug: "km-001", cards: 3, into: context, status: .active)
        insertConcept(slug: "km-002", cards: 3, into: context)

        let all = try context.fetch(FetchDescriptor<Card>())
        let ids = ConceptRelease.plan(ConceptRelease.candidates(in: all), target: 100)
        XCTAssertEqual(ids.count, 3)
    }

    func testAskingForNothingReleasesNothing() throws {
        let context = try makeContext()
        insertConcept(slug: "km-001", cards: 3, into: context)
        let all = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(ConceptRelease.plan(ConceptRelease.candidates(in: all), target: 0).isEmpty)
    }

    // MARK: - Applying

    func testReleasingMakesCardsActiveAndDueNow() throws {
        let context = try makeContext()
        let made = insertConcept(slug: "km-001", cards: 3, into: context)
        // Queued three months ago: the due date it carried must not survive, or
        // the cards arrive three months overdue and FSRS reads that lateness as
        // evidence about the owner's memory.
        for card in made.cards { card.dueDate = now.addingTimeInterval(-90 * 86_400) }

        let releaseDay = now.addingTimeInterval(90 * 86_400)
        let moved = try ConceptRelease.release(ids: made.cards.map(\.id), in: context, now: releaseDay)

        XCTAssertEqual(moved, 3)
        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.status == .active })
        XCTAssertTrue(cards.allSatisfy { $0.dueDate == releaseDay })
    }

    /// The button can be pressed twice before the view refreshes. The second
    /// press must not pull already-released cards back to the front of the queue.
    func testReleasingTwiceDoesNotRescheduleWhatWasAlreadyReleased() throws {
        let context = try makeContext()
        let made = insertConcept(slug: "km-001", cards: 3, into: context)
        let ids = made.cards.map(\.id)

        XCTAssertEqual(try ConceptRelease.release(ids: ids, in: context, now: now), 3)
        let later = now.addingTimeInterval(3600)
        XCTAssertEqual(try ConceptRelease.release(ids: ids, in: context, now: later), 0)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.dueDate == self.now }, "ikinci basış vadeleri kaydırmamalı")
    }

    func testReleasingAnEmptyListIsANoOp() throws {
        let context = try makeContext()
        insertConcept(slug: "km-001", cards: 2, into: context)
        XCTAssertEqual(try ConceptRelease.release(ids: [], in: context, now: now), 0)
    }

    // MARK: - The gate itself

    /// The reason the queue works at all: every study pool asks either "is this
    /// active?" or "is this withheld?", and a queued card fails both.
    func testAQueuedCardIsWithheldFromEveryPool() {
        XCTAssertTrue(CardStatus.queued.isWithheld)
        XCTAssertTrue(CardStatus.suspended.isWithheld)
        // Unchanged by this feature, asserted so a later edit to `isWithheld`
        // cannot quietly take pre-existing cards out of the deck.
        for status in [CardStatus.active, .draft, .needsReview] {
            XCTAssertFalse(status.isWithheld, "\(status) deste dışı sayılmamalı")
        }
    }

    /// A queued card is never offered by the review planner, whatever its due
    /// date — the property that makes importing a 3.000-card pack safe.
    func testTheReviewPlannerNeverOffersAQueuedCard() {
        let queued = PlannableCard(
            id: UUID(), dueDate: now.addingTimeInterval(-86_400),
            knowledgeUnitId: nil, status: .queued, reviewCount: 0
        )
        let active = PlannableCard(
            id: UUID(), dueDate: now.addingTimeInterval(-86_400),
            knowledgeUnitId: nil, status: .active, reviewCount: 0
        )
        let session = ReviewSessionPlanner.session(
            cards: [queued, active], now: now, newCardLimit: 50
        )
        XCTAssertEqual(session, [active.id])
    }
}
