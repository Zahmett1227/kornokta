import XCTest
import SwiftData
@testable import CizgiCore

/// The collection split's one real hazard, pinned down.
///
/// Splitting the deck introduced exactly one way to break a working app: miss
/// the filter at a single call site and an imported pack's 3.017 cards pour
/// into Tekrar, Egzersiz, Bilgilerim or the reminder counts. Nothing detects
/// that by itself — every one of those cards is valid, active and due, so the
/// screen looks healthy while showing the wrong deck.
///
/// These run against a real in-memory `ModelContainer` for the same reason
/// `ApprovalGateReleaseTests` does: `collection` is a computed bridge over
/// `collectionRaw`, and a filter that silently matched nothing would look
/// exactly like a filter that worked.
final class CardScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    @discardableResult
    private func insert(
        _ collection: CardCollection,
        into context: ModelContext,
        subject: String? = nil,
        topic: String? = nil,
        front: String = "soru"
    ) -> Card {
        let card = Card(
            type: .directRecall,
            front: front,
            back: "cevap",
            status: .active,
            createdAt: now,
            dueDate: now.addingTimeInterval(-60),
            collection: collection
        )
        if subject != nil || topic != nil {
            let unit = KnowledgeUnit(canonicalClaim: front, subject: subject, topic: topic)
            context.insert(unit)
            card.knowledgeUnit = unit
        }
        // Not new, so the planner's daily introduction limit cannot be what
        // holds a card back in the assertions below.
        card.reviewCount = 3
        context.insert(card)
        return card
    }

    // MARK: - The primitive

    func testEachCollectionSeesOnlyItsOwnCards() throws {
        let context = try makeContext()
        for _ in 0..<3 { insert(.capture, into: context) }
        for _ in 0..<5 { insert(.concept, into: context) }
        let all = try context.fetch(FetchDescriptor<Card>())

        XCTAssertEqual(CardScope.cards(all, in: .capture).count, 3)
        XCTAssertEqual(CardScope.cards(all, in: .concept).count, 5)
    }

    /// Existing cards carry no stored value at all until SwiftData fills the
    /// column from the property default. Reading `.capture` there is what makes
    /// this change invisible to a user who never imports a pack.
    func testACardMadeTheOldWayIsACaptureCard() throws {
        let context = try makeContext()
        let card = Card(type: .directRecall, front: "soru", back: "cevap")
        context.insert(card)

        XCTAssertEqual(card.collection, .capture)
        XCTAssertEqual(card.collectionRaw, "capture")
    }

    func testAnUnreadableStoredValueFallsBackToCapture() throws {
        let context = try makeContext()
        let card = Card(type: .directRecall, front: "soru", back: "cevap")
        context.insert(card)
        card.collectionRaw = "bir-gün-eklenmiş-başka-şey"

        XCTAssertEqual(card.collection, .capture)
        XCTAssertEqual(CardScope.cards([card], in: .capture).count, 1)
    }

    func testAnAbsentOrUnknownStoredScopeReadsAsCapture() {
        XCTAssertEqual(CardScope.collection(fromStored: ""), .capture)
        XCTAssertEqual(CardScope.collection(fromStored: "concept"), .concept)
        XCTAssertEqual(CardScope.collection(fromStored: "kavram"), .capture)
    }

    // MARK: - Tekrar (ReviewView)

    func testAReviewSessionNeverCrossesCollections() throws {
        let context = try makeContext()
        let capture = (0..<3).map { _ in insert(.capture, into: context) }
        let concept = (0..<4).map { _ in insert(.concept, into: context) }
        let all = try context.fetch(FetchDescriptor<Card>())

        func session(in collection: CardCollection) -> [UUID] {
            ReviewSessionPlanner.session(
                cards: CardScope.cards(all, in: collection).map {
                    PlannableCard(
                        id: $0.id,
                        dueDate: $0.dueDate,
                        knowledgeUnitId: $0.knowledgeUnit?.id,
                        status: $0.status,
                        reviewCount: $0.reviewCount
                    )
                },
                now: now,
                newCardLimit: 100
            )
        }

        let captureIds = Set(capture.map(\.id))
        let conceptIds = Set(concept.map(\.id))

        XCTAssertEqual(Set(session(in: .capture)), captureIds)
        XCTAssertEqual(Set(session(in: .concept)), conceptIds)
        XCTAssertTrue(Set(session(in: .capture)).isDisjoint(with: conceptIds))
        XCTAssertTrue(Set(session(in: .concept)).isDisjoint(with: captureIds))
    }

    // MARK: - Egzersiz (ExerciseView)

    /// `ExerciseView.eligibleCards` is scope → status → `ExerciseFilter`. An
    /// otherwise empty filter must not become a way back to the whole store.
    func testExerciseEligibilityNeverCrossesCollections() throws {
        let context = try makeContext()
        insert(.capture, into: context, subject: "Patoloji", topic: "Neoplazi")
        for _ in 0..<6 { insert(.concept, into: context, subject: "Farmakoloji", topic: "Genel Farmakoloji") }
        let all = try context.fetch(FetchDescriptor<Card>())

        func eligible(in collection: CardCollection) -> [Card] {
            let filter = ExerciseFilter()
            return CardScope.cards(all, in: collection).filter { card in
                card.status != .suspended
                    && filter.matches(
                        ExerciseCandidate(
                            id: card.id,
                            subject: card.knowledgeUnit?.subject,
                            topic: card.knowledgeUnit?.topic,
                            type: card.type,
                            reviewCount: card.reviewCount,
                            dueDate: card.dueDate,
                            lowConfidence: card.lowConfidence,
                            createdAt: card.createdAt,
                            fesScore: card.fesScore
                        ),
                        now: now
                    )
            }
        }

        XCTAssertEqual(eligible(in: .capture).count, 1)
        XCTAssertEqual(eligible(in: .concept).count, 6)
        XCTAssertTrue(eligible(in: .capture).allSatisfy { $0.collection == .capture })
        XCTAssertTrue(eligible(in: .concept).allSatisfy { $0.collection == .concept })
    }

    // MARK: - Bilgilerim (LibraryView)

    /// The screen's counts come from the same property as its list, so proving
    /// the scoped set is what reaches `LibraryCardFilter` covers both.
    func testLibraryListingAndCountsNeverCrossCollections() throws {
        let context = try makeContext()
        insert(.capture, into: context, subject: "Patoloji", topic: "Neoplazi", front: "çekim kartı")
        insert(.concept, into: context, subject: "Farmakoloji", topic: "Genel Farmakoloji", front: "kavram kartı")
        let all = try context.fetch(FetchDescriptor<Card>())

        func listed(in collection: CardCollection) -> [Card] {
            CardScope.cards(all, in: collection).filter { card in
                LibraryCardFilter.matches(
                    subject: card.knowledgeUnit?.subject,
                    topic: card.knowledgeUnit?.topic,
                    subjectFilter: nil,
                    topicFilter: .all
                )
            }
        }

        XCTAssertEqual(listed(in: .capture).map(\.front), ["çekim kartı"])
        XCTAssertEqual(listed(in: .concept).map(\.front), ["kavram kartı"])
    }

    /// A search has to stay inside the deck too: `CardSearch` runs *after*
    /// `CardScope`, and a term that matches in the other collection must find
    /// nothing rather than reaching across.
    func testSearchStaysInsideTheActiveCollection() throws {
        let context = try makeContext()
        insert(.concept, into: context, front: "Adrenerjik reseptörler")
        let all = try context.fetch(FetchDescriptor<Card>())

        func hits(in collection: CardCollection) -> Int {
            CardScope.cards(all, in: collection)
                .filter {
                    CardSearch.matches(
                        query: "adrenerjik",
                        front: $0.front,
                        back: $0.back,
                        explanation: $0.explanation,
                        tags: [],
                        subject: nil,
                        topic: nil,
                        optionTexts: []
                    )
                }
                .count
        }

        XCTAssertEqual(hits(in: .concept), 1)
        XCTAssertEqual(hits(in: .capture), 0)
    }

    // MARK: - Bilgi Haritası (KnowledgeMapView)

    /// The map describes one deck, not the store: an imported Farmakoloji pack
    /// must not light up topics for the photographed deck, or the coverage
    /// tiles would be answering about cards the screen is not showing.
    func testKnowledgeMapCoverageNeverCrossesCollections() throws {
        let context = try makeContext()
        let schema = SubjectTopicSchema(
            version: 1,
            subjects: [.init(name: "Farmakoloji", topics: ["Genel Farmakoloji", "Otokoidler ve NSAİİ"])]
        )
        insert(.concept, into: context, subject: "Farmakoloji", topic: "Genel Farmakoloji")
        let all = try context.fetch(FetchDescriptor<Card>())

        func map(in collection: CardCollection) -> KnowledgeMapSummary {
            KnowledgeMapBuilder.build(
                cards: CardScope.cards(all, in: collection).map {
                    KnowledgeMapCard(
                        subject: $0.knowledgeUnit?.subject,
                        topic: $0.knowledgeUnit?.topic,
                        isActive: $0.status == .active,
                        lapseCount: $0.lapseCount,
                        lowConfidence: $0.lowConfidence
                    )
                },
                schema: schema
            )
        }

        // Seen from the concept deck, one of the two topics is covered.
        XCTAssertEqual(map(in: .concept).coveredTopicCount, 1)
        XCTAssertEqual(map(in: .concept).totalCardCount, 1)
        // Seen from the photographed deck, neither is: it has no cards at all.
        XCTAssertEqual(map(in: .capture).coveredTopicCount, 0)
        XCTAssertEqual(map(in: .capture).totalCardCount, 0)
    }
}
