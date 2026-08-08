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

    // MARK: Restore path (Codex, PR #32)

    private func restored(_ existing: String?) throws -> String? {
        SubjectBackfill.restoredSubject(
            existing: existing,
            schema: try SubjectTopicSchema.bundled(),
            fallback: "Patoloji"
        )
    }

    func testRestoreNormalizesLegacySubjectsTheMigrationWillNeverSee() throws {
        // The migration flag is set on a fresh install's first launch, while
        // the store is empty; a backup restored afterwards never meets it.
        XCTAssertEqual(try restored("patoloji"), "Patoloji")
        XCTAssertEqual(try restored("PATOLOJİ"), "Patoloji")
        XCTAssertEqual(try restored("eski serbest metin"), "Patoloji")
        XCTAssertEqual(try restored("Farmakoloji"), "Farmakoloji")
    }

    func testRestoreKeepsAnAbsentSubjectAbsent() throws {
        // Unlike the migration: after the picker shipped, "Seçilmedi" is a
        // real choice, and overwriting it with the fallback would invent data.
        XCTAssertNil(try restored(nil))
        XCTAssertNil(try restored(""))
        XCTAssertNil(try restored("   "))
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
