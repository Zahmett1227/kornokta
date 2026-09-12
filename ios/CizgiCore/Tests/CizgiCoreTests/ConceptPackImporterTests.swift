import XCTest
import SwiftData
@testable import CizgiCore

/// Bulk import of a concept pack.
///
/// The three properties worth locking are the ones a hand test would not catch
/// on a 3.017-card file: importing twice must not double the deck, a concept's
/// cards must share one `KnowledgeUnit`, and a card type this build has never
/// heard of must degrade instead of failing the import.
final class ConceptPackImporterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeContext() throws -> ModelContext {
        let container = try ModelContainer(
            for: CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    private let schema = SubjectTopicSchema(
        version: 1,
        subjects: [.init(name: "Farmakoloji", topics: ["Genel Farmakoloji", "Endokrin Sistem Farmakolojisi"])]
    )

    /// Shaped exactly like the real file, including the fields the importer is
    /// expected to ignore or fold together.
    private func packJSON(
        cardType: String = "distinction",
        konu: String = "Genel Farmakoloji",
        dogrulama: String = "ocr",
        uyari: String? = nil,
        kaynakDuzeltmesi: String? = nil,
        cardCount: Int = 3,
        formatVersion: Int = 1,
        kitapSayfa: String = "\"242-243\""
    ) -> Data {
        let cards = (0..<cardCount).map { i in
            """
            {"id":"00000000-0000-0000-0000-00000000000\(i)","type":"\(cardType)",
             "originalType":"\(cardType)","front":"soru \(i)","back":"cevap \(i)",
             "explanation":null}
            """
        }.joined(separator: ",")
        let json = """
        {"formatVersion":\(formatVersion),"generatedAt":"2026-09-09","ders":"Farmakoloji",
         "kaynak":"TUSDATA","kavramlar":[
          {"id":"11111111-1111-1111-1111-111111111111","slug":"end-001",
           "ad":"Hormonlar","tanim":"Peptid yapıda olanlar…","ders":"Farmakoloji",
           "konu":"\(konu)","kaynak":"TUSDATA","kitapSayfa":\(kitapSayfa),
           "sayfaAraligi":[242,243],"dogrulama":"\(dogrulama)",
           "uyari":\(uyari.map { "\"\($0)\"" } ?? "null"),
           "kaynakDuzeltmesi":\(kaynakDuzeltmesi.map { "\"\($0)\"" } ?? "null"),
           "altKonu":null,"dosya":"end_01.json","kartlar":[\(cards)]}
        ]}
        """
        return Data(json.utf8)
    }

    private func importAll(_ data: Data, into context: ModelContext) throws -> ConceptPackImporter.Summary {
        let pack = try ConceptPackImporter.decode(data)
        let existing = Set(try context.fetch(FetchDescriptor<Card>()).map(\.id))
        let plan = ConceptPackImporter.plan(pack: pack, existingCardIds: existing)
        var inserted = 0
        let units = try context.fetch(FetchDescriptor<KnowledgeUnit>())
        for planned in plan.concepts {
            inserted += ConceptPackImporter.insert(
                planned,
                into: context,
                existingUnit: units.first { $0.id == planned.concept.id },
                schema: schema,
                now: now
            )
        }
        try context.save()
        return .init(
            insertedCards: inserted,
            insertedConcepts: plan.concepts.count,
            skippedCards: plan.skipped.count
        )
    }

    // MARK: - Idempotency

    /// (a) The same file twice adds nothing the second time. The pack's ids are
    /// `uuid5`-derived, so this also covers re-importing a regenerated pack.
    func testImportingTheSameFileTwiceAddsNothing() throws {
        let context = try makeContext()
        let data = packJSON()

        let first = try importAll(data, into: context)
        XCTAssertEqual(first.insertedCards, 3)
        XCTAssertEqual(first.skippedCards, 0)

        let second = try importAll(data, into: context)
        XCTAssertEqual(second.insertedCards, 0)
        XCTAssertEqual(second.skippedCards, 3)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 3)
        XCTAssertEqual(try context.fetch(FetchDescriptor<KnowledgeUnit>()).count, 1)
    }

    /// A later revision of the pack that adds a card to an existing concept
    /// must extend that concept, not fork a second copy of it.
    func testANewCardJoinsTheConceptThatIsAlreadyHere() throws {
        let context = try makeContext()
        try importAll(packJSON(cardCount: 2), into: context)
        try importAll(packJSON(cardCount: 3), into: context)

        let units = try context.fetch(FetchDescriptor<KnowledgeUnit>())
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].cards.count, 3)
    }

    /// A malformed file that repeats an id inside itself must not attempt two
    /// inserts under one `@Attribute(.unique)` id.
    func testARepeatedIdInsideOneFileIsInsertedOnce() throws {
        let context = try makeContext()
        let pack = try ConceptPackImporter.decode(packJSON(cardCount: 2))
        let doubled = ConceptPackImporter.Pack(
            formatVersion: pack.formatVersion,
            ders: pack.ders,
            kavramlar: pack.kavramlar + pack.kavramlar
        )
        let plan = ConceptPackImporter.plan(pack: doubled, existingCardIds: [])

        XCTAssertEqual(plan.cardCount, 2)
        XCTAssertEqual(plan.skipped.count, 2)
    }

    // MARK: - Grouping

    /// (b) A concept's cards hang off one unit — the reason this format exists
    /// at all, since a backup restore gives every card a unit of its own.
    func testAllOfAConceptsCardsShareOneKnowledgeUnit() throws {
        let context = try makeContext()
        try importAll(packJSON(cardCount: 4), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        let units = Set(cards.compactMap { $0.knowledgeUnit?.id })
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first, UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    }

    /// The unit carries no region, and that is the point: inventing a
    /// placeholder page would put a falsehood behind "Kaynağı göster".
    func testAnImportedConceptHasNoPageBehindIt() throws {
        let context = try makeContext()
        try importAll(packJSON(), into: context)

        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertNil(unit.region)
        XCTAssertEqual(unit.canonicalClaim, "Peptid yapıda olanlar…")
        XCTAssertTrue(unit.tags.contains(ConceptPackImporter.tag))
        XCTAssertTrue(unit.tags.contains("end-001"))
    }

    // MARK: - Card mapping

    /// (c) `CardType` is locked to the backend schema, so a pack written
    /// against a newer one has to degrade rather than refuse. The real pack
    /// already does this for its 466 `sirali_coklu` cards.
    func testAnUnknownCardTypeBecomesDirectRecallInsteadOfFailing() throws {
        let context = try makeContext()
        let summary = try importAll(packJSON(cardType: "sirali_coklu"), into: context)

        XCTAssertEqual(summary.insertedCards, 3)
        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.type == .directRecall })
    }

    /// Renamed from `...ActiveAndDue` on 2026-09-10: a pack now lands queued,
    /// and the point of this test is the one thing that must never regress —
    /// that importing a file does not put thousands of cards into Tekrar.
    func testImportedCardsLandInTheConceptDeckQueuedAndInvisible() throws {
        let context = try makeContext()
        try importAll(packJSON(), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.collection == .concept })
        XCTAssertTrue(cards.allSatisfy { $0.status == .queued })
        // The gate that keeps them out of every pool, asserted on the property
        // the three "is this card in play?" call sites actually read.
        XCTAssertTrue(cards.allSatisfy { $0.status.isWithheld })
        // Page reference, so the source screen has something true to show.
        XCTAssertTrue(cards.allSatisfy { $0.sourceQuote == "242-243" })
        // They start unstudied like any freshly made card.
        XCTAssertTrue(cards.allSatisfy { $0.reviewCount == 0 })
    }

    /// A concept the pack could not read off the page is flagged the way an
    /// uncertain generated card is, so it surfaces in "Gözden geçir".
    func testCorpusSourcedConceptsAreFlaggedForReview() throws {
        let context = try makeContext()
        try importAll(packJSON(dogrulama: "korpus"), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy(\.lowConfidence))
        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertFalse(unit.sourceFaithful)
    }

    func testOcrSourcedConceptsAreNotFlagged() throws {
        let context = try makeContext()
        try importAll(packJSON(dogrulama: "ocr"), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { !$0.lowConfidence })
        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertTrue(unit.sourceFaithful)
    }

    /// Both caveat fields survive, because they say different things and the
    /// card detail has one place to show either.
    func testBothCaveatFieldsReachSourceConcern() throws {
        let context = try makeContext()
        try importAll(
            packJSON(uyari: "Kaynakta çelişki var", kaynakDuzeltmesi: "Doz düzeltildi"),
            into: context
        )

        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertEqual(unit.sourceConcern, "Kaynakta çelişki var · Doz düzeltildi")
    }

    func testNoCaveatsMeansNoConcern() throws {
        let context = try makeContext()
        try importAll(packJSON(), into: context)
        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertNil(unit.sourceConcern)
    }

    // MARK: - Classification

    /// The pack is already remapped onto the canonical schema; this is the
    /// guard that keeps a drifted one from quietly creating a topic that no
    /// filter and no Bilgi Haritası row can ever match.
    func testATopicOutsideTheSchemaIsDroppedRatherThanInvented() throws {
        let context = try makeContext()
        try importAll(packJSON(konu: "Toksikoloji"), into: context)

        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertEqual(unit.subject, "Farmakoloji")
        XCTAssertNil(unit.topic)
    }

    func testACanonicalTopicIsKept() throws {
        let context = try makeContext()
        try importAll(packJSON(konu: "Endokrin Sistem Farmakolojisi"), into: context)

        let unit = try XCTUnwrap(try context.fetch(FetchDescriptor<KnowledgeUnit>()).first)
        XCTAssertEqual(unit.topic, "Endokrin Sistem Farmakolojisi")
    }

    // MARK: - The file itself

    func testAFileFromANewerBuildIsRefusedRatherThanPartlyRead() {
        XCTAssertThrowsError(try ConceptPackImporter.decode(packJSON(formatVersion: 2))) { error in
            XCTAssertEqual(error as? ConceptPackImporter.ImportError, .unsupportedVersion(2))
        }
    }

    func testGibberishIsRefused() {
        XCTAssertThrowsError(try ConceptPackImporter.decode(Data("nope".utf8)))
    }

    // MARK: - Batched writing

    @MainActor
    func testRunWritesEveryCardAndReportsWhatItDid() async throws {
        let context = try makeContext()
        let pack = try ConceptPackImporter.decode(packJSON(cardCount: 5))
        let plan = ConceptPackImporter.plan(pack: pack, existingCardIds: [])

        var lastReported = 0
        let summary = try await ConceptPackImporter.run(
            plan: plan,
            into: context,
            batchSize: 2,
            schema: schema,
            now: now,
            progress: { done, total in
                lastReported = done
                XCTAssertEqual(total, 5)
            }
        )

        XCTAssertEqual(summary.insertedCards, 5)
        XCTAssertEqual(summary.insertedConcepts, 1)
        XCTAssertEqual(lastReported, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Card>()).count, 5)
    }

    // MARK: - The pack's own irregularities

    /// `kitapSayfa` is a page reference, not a number, and the real pack writes
    /// it both ways: 741 concepts quote it, 90 do not. This is not a
    /// hypothetical — decoding it as `String` alone aborted the real 3.017-card
    /// import at concept 559, and `JSONDecoder` gives up on the whole file at
    /// the first mismatch, so the other 830 concepts came in too.
    func testABarePageNumberDecodesLikeAQuotedOne() throws {
        let context = try makeContext()
        try importAll(packJSON(kitapSayfa: "448"), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertEqual(cards.count, 3)
        XCTAssertTrue(cards.allSatisfy { $0.sourceQuote == "448" })
    }

    func testAQuotedPageRangeIsUnchanged() throws {
        let context = try makeContext()
        try importAll(packJSON(kitapSayfa: "\"242-243\""), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.sourceQuote == "242-243" })
    }

    func testAMissingPageReferenceIsSimplyAbsent() throws {
        let context = try makeContext()
        try importAll(packJSON(kitapSayfa: "null"), into: context)

        let cards = try context.fetch(FetchDescriptor<Card>())
        XCTAssertTrue(cards.allSatisfy { $0.sourceQuote == nil })
    }

    /// A page reference that is neither must fail loudly rather than import a
    /// concept whose provenance line is a decoded fragment of something else.
    func testAStructuredPageReferenceIsRefused() {
        XCTAssertThrowsError(try ConceptPackImporter.decode(packJSON(kitapSayfa: "{\"a\":1}")))
    }
}
