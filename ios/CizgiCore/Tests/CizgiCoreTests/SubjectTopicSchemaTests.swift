import XCTest
@testable import CizgiCore

final class SubjectTopicSchemaTests: XCTestCase {
    func testBundledTemplateCarriesTheTusoskopCounts() throws {
        let schema = try SubjectTopicSchema.bundled()
        XCTAssertEqual(schema.subjects.count, 11)
        XCTAssertEqual(schema.subjects.reduce(0) { $0 + $1.topics.count }, 143)
        XCTAssertEqual(schema.topics(for: "Patoloji")?.count, 24)
        XCTAssertEqual(schema.topics(for: "Genel Cerrahi")?.count, 29)
    }

    func testSubjectOrderMatchesTheTemplate() throws {
        let schema = try SubjectTopicSchema.bundled()
        XCTAssertEqual(schema.subjectNames.first, "Fizyoloji")
        XCTAssertEqual(schema.subjectNames[1], "Patoloji")
        XCTAssertEqual(schema.subjectNames.last, "Anatomi")
    }

    func testValidityIsAlwaysASubjectTopicPair() throws {
        let schema = try SubjectTopicSchema.bundled()
        // "İmmünoloji" exists under two subjects — a bare topic lookup would lie.
        XCTAssertTrue(schema.isValidTopic("İmmünoloji", subject: "Patoloji"))
        XCTAssertTrue(schema.isValidTopic("İmmünoloji", subject: "Mikrobiyoloji"))
        XCTAssertFalse(schema.isValidTopic("İmmünoloji", subject: "Anatomi"))
        XCTAssertFalse(schema.isValidTopic("Bakteriyoloji", subject: "Patoloji"))
    }

    func testCanonicalSubjectMatchesTurkishCaseInsensitively() throws {
        let schema = try SubjectTopicSchema.bundled()
        XCTAssertEqual(schema.canonicalSubject(matching: "patoloji"), "Patoloji")
        // Dotted capital İ must round-trip under the Turkish locale.
        XCTAssertEqual(schema.canonicalSubject(matching: "PATOLOJİ"), "Patoloji")
        XCTAssertEqual(schema.canonicalSubject(matching: "  Genel Cerrahi  "), "Genel Cerrahi")
        XCTAssertEqual(schema.canonicalSubject(matching: "kadın hastalıkları ve doğum"),
                       "Kadın Hastalıkları ve Doğum")
        XCTAssertNil(schema.canonicalSubject(matching: "eski serbest metin"))
        XCTAssertNil(schema.canonicalSubject(matching: ""))
        XCTAssertNil(schema.canonicalSubject(matching: "   "))
        XCTAssertNil(schema.canonicalSubject(matching: nil))
    }
}
