import XCTest
@testable import CizgiCore

final class SubjectBackfillTests: XCTestCase {
    private func resolve(_ existing: String?) throws -> String? {
        SubjectBackfill.resolvedSubject(
            existing: existing,
            schema: try SubjectTopicSchema.bundled(),
            fallback: "Patoloji"
        )
    }

    func testNilAndBlankBecomeTheFallback() throws {
        XCTAssertEqual(try resolve(nil), "Patoloji")
        XCTAssertEqual(try resolve(""), "Patoloji")
        XCTAssertEqual(try resolve("   "), "Patoloji")
    }

    func testUnrecognizedFreeTextBecomesTheFallback() throws {
        // The legacy Settings field was free text; the user confirmed the
        // whole pre-migration deck is Patoloji.
        XCTAssertEqual(try resolve("eski serbest metin"), "Patoloji")
        XCTAssertEqual(try resolve("pato"), "Patoloji")
    }

    func testCasingVariantsNormalizeToTheCanonicalSpelling() throws {
        XCTAssertEqual(try resolve("patoloji"), "Patoloji")
        XCTAssertEqual(try resolve("PATOLOJİ"), "Patoloji")
        XCTAssertEqual(try resolve("farmakoloji"), "Farmakoloji")
    }

    func testAnAlreadyCanonicalSubjectIsLeftUntouched() throws {
        // nil = "no write" — the guarantee that makes a re-run after a failed
        // save harmless, and that keeps a real classification from being
        // overwritten with the fallback.
        XCTAssertNil(try resolve("Patoloji"))
        XCTAssertNil(try resolve("Farmakoloji"))
        XCTAssertNil(try resolve("Kadın Hastalıkları ve Doğum"))
    }
}
