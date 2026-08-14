import XCTest
import SwiftData
@testable import CizgiCore

/// Finding the `KnowledgeUnit` a card belongs on (2026-08-15).
///
/// The first tests in this package to stand up a `ModelContainer`. It is
/// in-memory only, so nothing touches disk and the suite stays as fast as the
/// rest — but it does mean these run on a Mac, which is where `swift test`
/// already runs for this package (CoreGraphics/SwiftData never built on Linux;
/// see CLAUDE.md's environment note).
///
/// What is actually being defended: a unit is shared by every card on the page
/// that got the same topic, so classifying one card must never edit a unit its
/// siblings are sitting on.
final class UnitBindingTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private func makeRegion(in context: ModelContext) -> TextRegion {
        let region = TextRegion(
            boundingBox: (0, 0, 1, 1),
            lineIds: [],
            finalText: "Sayfanın okunan metni",
            confidence: 1
        )
        context.insert(region)
        return region
    }

    func testAnExistingUnitWithTheSamePairIsReused() throws {
        let context = try makeContext()
        let region = makeRegion(in: context)
        let existing = KnowledgeUnit(canonicalClaim: "İddia", subject: "Patoloji", topic: "Hücre zedelenmesi")
        existing.region = region
        context.insert(existing)

        let found = KnowledgeUnitBinding.findOrCreate(
            on: region,
            subject: "Patoloji",
            topic: "Hücre zedelenmesi",
            claim: "Başka bir iddia",
            context: context
        )

        XCTAssertIdentical(found, existing)
        // Reused, not rewritten: the claim of a unit siblings share is theirs.
        XCTAssertEqual(existing.canonicalClaim, "İddia")
        XCTAssertEqual(region.knowledgeUnits.count, 1)
    }

    func testADifferentPairGetsItsOwnUnitOnTheSameRegion() throws {
        let context = try makeContext()
        let region = makeRegion(in: context)
        let sibling = KnowledgeUnit(canonicalClaim: "İddia", subject: "Patoloji", topic: "Hücre zedelenmesi")
        sibling.region = region
        context.insert(sibling)

        let created = KnowledgeUnitBinding.findOrCreate(
            on: region,
            subject: "Patoloji",
            topic: "İnflamasyon",
            claim: "Elle yazılan kartın sorusu",
            context: context
        )

        XCTAssertNotIdentical(created, sibling)
        XCTAssertEqual(created.topic, "İnflamasyon")
        XCTAssertEqual(created.canonicalClaim, "Elle yazılan kartın sorusu")
        // Bound to the same region, which is what keeps "Kaynağı göster" able to
        // show the page photo for the card that lands here.
        XCTAssertIdentical(created.region, region)
        // The sibling is untouched — the whole point of find-or-create.
        XCTAssertEqual(sibling.topic, "Hücre zedelenmesi")
        XCTAssertEqual(region.knowledgeUnits.count, 2)
    }

    /// A unit with no ders/konu at all is a real pair too (the "Konusuz" bucket),
    /// so it has to be matched rather than duplicated on every call.
    func testAnUnclassifiedUnitIsMatchedOnNilNil() throws {
        let context = try makeContext()
        let region = makeRegion(in: context)
        let unclassified = KnowledgeUnit(canonicalClaim: "İddia")
        unclassified.region = region
        context.insert(unclassified)

        let found = KnowledgeUnitBinding.findOrCreate(
            on: region, subject: nil, topic: nil, claim: "Soru", context: context
        )
        XCTAssertIdentical(found, unclassified)
    }

    /// A card can carry a ders/konu with no page behind it — this is what a
    /// restored backup's cards look like.
    func testWithoutARegionAnUnboundUnitIsCreated() throws {
        let context = try makeContext()
        let created = KnowledgeUnitBinding.findOrCreate(
            on: nil, subject: "Farmakoloji", topic: nil, claim: "Soru", context: context
        )
        XCTAssertNil(created.region)
        XCTAssertEqual(created.subject, "Farmakoloji")
    }

    func testTagsAndConcernAreCarriedOntoANewUnit() throws {
        let context = try makeContext()
        let region = makeRegion(in: context)
        let created = KnowledgeUnitBinding.findOrCreate(
            on: region,
            subject: "Patoloji",
            topic: "İnflamasyon",
            claim: "Soru",
            tags: ["kenar notu"],
            sourceConcern: "El yazısı okunamadı",
            context: context
        )
        XCTAssertEqual(created.tags, ["kenar notu"])
        XCTAssertEqual(created.sourceConcern, "El yazısı okunamadı")
    }
}
