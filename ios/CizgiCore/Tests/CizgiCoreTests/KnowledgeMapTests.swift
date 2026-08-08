import XCTest
@testable import CizgiCore

final class KnowledgeMapTests: XCTestCase {
    private let schema = SubjectTopicSchema(
        version: 1,
        subjects: [
            .init(name: "Patoloji", topics: ["Inflamasyon", "Neoplazi"]),
            .init(name: "Farmakoloji", topics: ["Otonom"]),
        ]
    )

    private func card(
        _ subject: String?,
        _ topic: String?,
        active: Bool = true,
        lapses: Int = 0,
        lowConfidence: Bool = false
    ) -> KnowledgeMapCard {
        KnowledgeMapCard(
            subject: subject,
            topic: topic,
            isActive: active,
            lapseCount: lapses,
            lowConfidence: lowConfidence
        )
    }

    func testBuildKeepsCanonicalOrderAndCountsCoverage() {
        let map = KnowledgeMapBuilder.build(
            cards: [
                card("Patoloji", "Inflamasyon", lapses: 2),
                card("Patoloji", "Inflamasyon", active: false, lowConfidence: true),
                card("Patoloji", nil),
            ],
            schema: schema
        )

        XCTAssertEqual(map.subjects.map(\.subject), ["Patoloji", "Farmakoloji"])
        XCTAssertEqual(map.subjects[0].cardCount, 3)
        XCTAssertEqual(map.subjects[0].coveredTopicCount, 1)
        XCTAssertEqual(map.subjects[0].totalTopicCount, 2)
        XCTAssertEqual(map.subjects[0].coverage, 0.5)
        XCTAssertEqual(map.subjects[0].weakCardCount, 2)
        XCTAssertEqual(map.subjects[0].topics[0].activeCount, 1)
        XCTAssertEqual(map.subjects[0].topics[0].lapseCount, 2)
        // Empty topics stay in the list; a coverage view exists to show them.
        XCTAssertEqual(map.subjects[0].topics.map(\.topic), ["Inflamasyon", "Neoplazi"])
    }

    func testUnknownNamesDoNotInventMapNodes() {
        let map = KnowledgeMapBuilder.build(
            cards: [
                card("Uydurma", "Bir sey", lapses: 1, lowConfidence: true),
                card("Patoloji", "Uydurma konu", lapses: 1, lowConfidence: true),
            ],
            schema: schema
        )

        XCTAssertEqual(map.subjects.map(\.subject), ["Patoloji", "Farmakoloji"])
        XCTAssertEqual(map.subjects[0].cardCount, 1)
        XCTAssertTrue(map.subjects[0].topics.allSatisfy { $0.cardCount == 0 })
    }

    /// The deck as it stands today: `SubjectBackfillMigration` gave every card
    /// a subject and left its topic nil. A canonical-nodes-only map showed that
    /// user an entirely empty screen.
    func testATopiclessDeckStillAppearsUnderItsSubject() {
        let map = KnowledgeMapBuilder.build(
            cards: [card("Patoloji", nil), card("Patoloji", nil, lapses: 3)],
            schema: schema
        )

        let patoloji = map.subjects[0]
        XCTAssertEqual(patoloji.cardCount, 2)
        XCTAssertEqual(patoloji.coveredTopicCount, 0)
        XCTAssertEqual(patoloji.uncategorized?.cardCount, 2)
        XCTAssertEqual(patoloji.uncategorized?.weakCardCount, 1)
        XCTAssertNil(patoloji.unrecognizedTopic)
    }

    /// Every card must be reachable from exactly one place on screen, or the
    /// header tiles and the rows below will disagree.
    func testEveryCardIsAccountedForExactlyOnce() {
        let cards = [
            card("Patoloji", "Inflamasyon"),
            card("Patoloji", "Neoplazi"),
            card("Patoloji", nil),
            card("Patoloji", "Bilinmeyen konu"),
            card("Farmakoloji", "Otonom"),
            card("Uydurma ders", "Otonom"),
            card(nil, nil),
        ]

        let map = KnowledgeMapBuilder.build(cards: cards, schema: schema)

        let accountedFor = map.subjects.reduce(0) { running, subject in
            let inTopics = subject.topics.reduce(0) { $0 + $1.cardCount }
            return running + inTopics
                + (subject.uncategorized?.cardCount ?? 0)
                + (subject.unrecognizedTopic?.cardCount ?? 0)
        } + (map.unclassified?.cardCount ?? 0)

        XCTAssertEqual(accountedFor, cards.count)
        XCTAssertEqual(map.totalCardCount, cards.count)
        XCTAssertEqual(map.unclassified?.cardCount, 2, "dersi tanınmayan + dersi olmayan")
        XCTAssertEqual(map.subjects[0].unrecognizedTopic?.cardCount, 1)
    }

    func testHeaderTotalsAreTheSumOfTheSubjectRows() {
        let map = KnowledgeMapBuilder.build(
            cards: [card("Patoloji", "Neoplazi"), card("Farmakoloji", "Otonom")],
            schema: schema
        )

        XCTAssertEqual(map.coveredTopicCount, map.subjects.reduce(0) { $0 + $1.coveredTopicCount })
        XCTAssertEqual(map.totalTopicCount, map.subjects.reduce(0) { $0 + $1.totalTopicCount })
        XCTAssertEqual(map.coveredTopicCount, 2)
        XCTAssertEqual(map.totalTopicCount, 3)
    }

    func testAnEmptyDeckHasNoBuckets() {
        let map = KnowledgeMapBuilder.build(cards: [], schema: schema)

        XCTAssertTrue(map.isEmpty)
        XCTAssertNil(map.unclassified)
        XCTAssertTrue(map.subjects.allSatisfy { $0.uncategorized == nil })
        XCTAssertEqual(map.subjects[0].coverage, 0)
    }
}
