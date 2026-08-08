import XCTest
@testable import CizgiCore

final class TopicGroupingTests: XCTestCase {
    private func card(_ front: String, topic: String? = nil) -> GeneratedCard {
        GeneratedCard(type: .directRecall, front: front, back: "b", sourceQuote: "", topic: topic)
    }

    private func schema() throws -> SubjectTopicSchema {
        try SubjectTopicSchema.bundled()
    }

    func testPartitionGroupsByTopicInFirstSeenOrder() throws {
        let cards = [
            card("a", topic: "İnflamasyon"),
            card("b", topic: "Neoplazi"),
            card("c", topic: "İnflamasyon"),
            card("d"),
        ]
        let groups = TopicGrouping.partition(cards, subject: "Patoloji", schema: try schema())

        XCTAssertEqual(groups.map(\.topic), ["İnflamasyon", "Neoplazi", nil])
        XCTAssertEqual(groups[0].cards.map(\.front), ["a", "c"])
        XCTAssertEqual(groups[1].cards.map(\.front), ["b"])
        XCTAssertEqual(groups[2].cards.map(\.front), ["d"])
    }

    func testAllTopiclessCardsStayOneGroup() throws {
        let groups = TopicGrouping.partition([card("a"), card("b")], subject: "Patoloji", schema: try schema())
        XCTAssertEqual(groups.count, 1)
        XCTAssertNil(groups[0].topic)
        XCTAssertEqual(groups[0].cards.count, 2)
    }

    func testInvalidTopicFallsIntoTheNilGroupInsteadOfBeingKept() throws {
        // "Bakteriyoloji" is a real topic — under Mikrobiyoloji, not Patoloji.
        let cards = [card("a", topic: "Bakteriyoloji"), card("b", topic: "İnflamasyon")]
        let groups = TopicGrouping.partition(cards, subject: "Patoloji", schema: try schema())
        XCTAssertEqual(groups.map(\.topic), [nil, "İnflamasyon"])
    }

    func testTopicWithoutASubjectIsDroppedToNil() throws {
        let groups = TopicGrouping.partition([card("a", topic: "İnflamasyon")], subject: nil, schema: try schema())
        XCTAssertEqual(groups.map(\.topic), [nil])
    }

    func testMissingSchemaKeepsTheServersValue() {
        // The bundled JSON failing to load is a local resource problem; the
        // server already validated the topic, so it is kept rather than wiped.
        let groups = TopicGrouping.partition([card("a", topic: "İnflamasyon")], subject: "Patoloji", schema: nil)
        XCTAssertEqual(groups.map(\.topic), ["İnflamasyon"])
    }
}
