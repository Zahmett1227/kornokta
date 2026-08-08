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

    func testBuildKeepsCanonicalOrderAndCountsCoverage() {
        let cards = [
            KnowledgeMapCard(subject: "Patoloji", topic: "Inflamasyon", isActive: true, lapseCount: 2, lowConfidence: false),
            KnowledgeMapCard(subject: "Patoloji", topic: "Inflamasyon", isActive: false, lapseCount: 0, lowConfidence: true),
            KnowledgeMapCard(subject: "Patoloji", topic: nil, isActive: true, lapseCount: 0, lowConfidence: false),
        ]

        let result = KnowledgeMapBuilder.build(cards: cards, schema: schema)

        XCTAssertEqual(result.map(\.subject), ["Patoloji", "Farmakoloji"])
        XCTAssertEqual(result[0].cardCount, 3)
        XCTAssertEqual(result[0].coveredTopicCount, 1)
        XCTAssertEqual(result[0].totalTopicCount, 2)
        XCTAssertEqual(result[0].coverage, 0.5)
        XCTAssertEqual(result[0].weakCardCount, 2)
        XCTAssertEqual(result[0].topics[0].activeCount, 1)
        XCTAssertEqual(result[0].topics[0].lapseCount, 2)
    }

    func testUnknownNamesDoNotInventMapNodes() {
        let cards = [
            KnowledgeMapCard(subject: "Uydurma", topic: "Bir sey", isActive: true, lapseCount: 1, lowConfidence: true),
            KnowledgeMapCard(subject: "Patoloji", topic: "Uydurma konu", isActive: true, lapseCount: 1, lowConfidence: true),
        ]

        let result = KnowledgeMapBuilder.build(cards: cards, schema: schema)

        XCTAssertEqual(result.map(\.subject), ["Patoloji", "Farmakoloji"])
        XCTAssertEqual(result[0].cardCount, 1)
        XCTAssertTrue(result[0].topics.allSatisfy { $0.cardCount == 0 })
    }
}
