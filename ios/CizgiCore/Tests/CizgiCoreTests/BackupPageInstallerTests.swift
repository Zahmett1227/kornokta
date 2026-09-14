import XCTest
import SwiftData
@testable import CizgiCore

/// Backup version 9: restoring a page photograph builds the chain "Kaynağı
/// göster" already walks (docs/ADR-011).
///
/// In-memory store (the `UnitBindingTests` pattern) and a scratch image
/// directory (the `ImageStoreTests` pattern): nothing touches the real app's
/// data, and every file an install writes can be counted.
final class BackupPageInstallerTests: XCTestCase {
    private var root: URL!
    private var store: ImageStore!
    private var context: ModelContext!
    private let schema = try? SubjectTopicSchema.bundled()
    private let captured = Date(timeIntervalSince1970: 1_770_000_000)
    private let jpeg = TestJPEG.tiny

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cizgi-restore-tests-\(UUID().uuidString)", isDirectory: true)
        store = try ImageStore(root: root)
        let container = try ModelContainer(
            for: Source.self, CapturedPage.self, TextRegion.self, KnowledgeUnit.self, Card.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pageRecord(
        id: UUID = UUID(),
        subject: String? = "Mikrobiyoloji",
        readText: String? = "★ Brucella: kültür en az 3 hafta",
        label: String? = "FA Mikrobiyoloji s.126"
    ) -> BackupExporter.PageRecord {
        BackupExporter.PageRecord(
            id: id, jpegData: jpeg, captureDate: captured,
            subject: subject, readText: readText, pageLabel: label
        )
    }

    private func cardRecord(pageId: UUID?) -> BackupExporter.CardRecord {
        BackupExporter.CardRecord(
            id: UUID(), type: "direct_recall", front: "Brucella kültürü ne kadar bekletilir?",
            back: "En az 3 hafta.", explanation: nil, sourceQuote: nil, subject: "Mikrobiyoloji",
            status: "active", dueDate: captured, stability: 0, difficulty: 0,
            reviewCount: 0, lapseCount: 0, pageId: pageId
        )
    }

    private func storedFileCount() -> Int {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { !$0.hasDirectoryPath } ?? []
        return files.count
    }

    // MARK: The page

    func testAPlannedPageIsBuiltReadyWithItsPhotoAndAWholePageRegion() throws {
        let record = pageRecord()
        let plan = BackupRestorer.plan(records: [cardRecord(pageId: record.id)], pages: [record], existingIds: [])

        let installed = try BackupPageInstaller.install(
            plan, imageStore: store, context: context, schema: schema, hash: { _ in "hash-1" }
        )
        try context.save()

        let page = try XCTUnwrap(try context.fetch(FetchDescriptor<CapturedPage>()).first)
        XCTAssertEqual(page.id, record.id)
        // `.ready` is the state the queue never picks up — the page must not
        // be sent to the job API.
        XCTAssertEqual(page.processingState, .ready)
        XCTAssertEqual(page.captureDate, captured)
        XCTAssertEqual(page.pageNumber, "FA Mikrobiyoloji s.126")
        XCTAssertEqual(page.perceptualHash, "hash-1")
        XCTAssertNil(page.coverageJSON, "kapsama defteri olmadan üretilmiş — doğrusu bu")
        XCTAssertEqual(try store.load(relativePath: page.originalImagePath), jpeg, "yeniden sıkıştırılmamalı")
        XCTAssertEqual(installed.writtenImagePaths, [page.originalImagePath])

        let region = try XCTUnwrap(page.regions.first)
        XCTAssertIdentical(installed.regions[record.id], region)
        XCTAssertEqual(page.regions.count, 1)
        XCTAssertEqual(region.selectionType, .manual)
        XCTAssertEqual(region.boundingBoxWidth, 1)
        XCTAssertEqual(region.boundingBoxHeight, 1)
        XCTAssertEqual(region.finalText, "★ Brucella: kültür en az 3 hafta")
        XCTAssertEqual(region.contextText, region.finalText)
        XCTAssertEqual(page.source?.subject, "Mikrobiyoloji")
    }

    /// The whole point of the version: a card hung off the installed region
    /// resolves to a photograph through the same path "Kaynağı göster" uses.
    func testALinkedCardResolvesItsPhotoThroughTheSourceChain() throws {
        let record = pageRecord()
        let cardRec = cardRecord(pageId: record.id)
        let plan = BackupRestorer.plan(records: [cardRec], pages: [record], existingIds: [])
        let installed = try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)

        let region = try XCTUnwrap(plan.pageLinks[cardRec.id].flatMap { installed.regions[$0] })
        let card = Card(id: cardRec.id, type: .directRecall, front: cardRec.front, back: cardRec.back, status: .active)
        card.knowledgeUnit = BackupPageInstaller.unit(
            on: region, subject: "Mikrobiyoloji", topic: "Bakteriyoloji",
            claim: "★ Brucella", tags: [], createdAt: captured, context: context
        )
        context.insert(card)
        try context.save()

        let page = card.knowledgeUnit?.region?.page
        let path = page?.originalImagePath
        let material = CardSourceResolver.material(
            cardFront: card.front,
            quote: card.sourceQuote,
            readText: card.knowledgeUnit?.canonicalClaim,
            subject: card.knowledgeUnit?.subject,
            pageImagePath: path,
            pageImageExists: path.map { store.exists(relativePath: $0) } ?? false,
            capturedAt: page?.captureDate
        )
        XCTAssertNotNil(material.pageImagePath)
        XCTAssertFalse(material.pageImageDiscarded)
        XCTAssertEqual(material.readText, "★ Brucella")
    }

    func testPagesOfOneSubjectShareOneSourceAndReuseAnExistingOne() throws {
        let existing = Source(title: "Mikrobiyoloji", subject: "Mikrobiyoloji")
        context.insert(existing)
        try context.save()

        let first = pageRecord(subject: "mikrobiyoloji")   // canonicalised
        let second = pageRecord(subject: " Mikrobiyoloji ")
        let third = pageRecord(subject: "Farmakoloji")
        let plan = BackupRestorer.plan(
            records: [first, second, third].map { cardRecord(pageId: $0.id) },
            pages: [first, second, third],
            existingIds: []
        )
        _ = try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)
        try context.save()

        let sources = try context.fetch(FetchDescriptor<Source>())
        XCTAssertEqual(sources.count, 2)
        let pages = try context.fetch(FetchDescriptor<CapturedPage>())
        let micro = pages.filter { $0.source?.subject == "Mikrobiyoloji" }
        XCTAssertEqual(micro.count, 2)
        XCTAssertTrue(micro.allSatisfy { $0.source?.id == existing.id })
    }

    func testAPageWithNoSubjectOrLabelGetsNoSourceAndNoLabel() throws {
        let record = pageRecord(subject: "  ", readText: nil, label: "")
        let plan = BackupRestorer.plan(records: [cardRecord(pageId: record.id)], pages: [record], existingIds: [])
        let installed = try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)

        let region = try XCTUnwrap(installed.regions[record.id])
        XCTAssertNil(region.page?.source)
        XCTAssertNil(region.page?.pageNumber)
        XCTAssertEqual(region.finalText, "")
        XCTAssertTrue(try context.fetch(FetchDescriptor<Source>()).isEmpty)
    }

    // MARK: A page the device already has

    /// (d) The second restore of the same page: the cards link to the region the
    /// first one built, and no image is written.
    func testAnExistingPageIsLinkedWithoutRewritingItsImage() throws {
        let record = pageRecord()
        let firstPlan = BackupRestorer.plan(records: [cardRecord(pageId: record.id)], pages: [record], existingIds: [])
        let first = try BackupPageInstaller.install(firstPlan, imageStore: store, context: context, schema: schema)
        try context.save()
        let filesAfterFirst = storedFileCount()

        let secondPlan = BackupRestorer.plan(
            records: [cardRecord(pageId: record.id)],
            pages: [record],
            existingIds: [],
            existingPageIds: [record.id]
        )
        let second = try BackupPageInstaller.install(secondPlan, imageStore: store, context: context, schema: schema)
        try context.save()

        XCTAssertIdentical(second.regions[record.id], first.regions[record.id])
        XCTAssertTrue(second.writtenImagePaths.isEmpty)
        XCTAssertEqual(storedFileCount(), filesAfterFirst)
        XCTAssertEqual(try context.fetch(FetchDescriptor<CapturedPage>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TextRegion>()).count, 1)
    }

    // MARK: Units

    func testCardsWithTheSameUnitPayloadShareOneUnitButDifferentTagsDoNot() throws {
        let record = pageRecord()
        let plan = BackupRestorer.plan(records: [cardRecord(pageId: record.id)], pages: [record], existingIds: [])
        let region = try XCTUnwrap(
            try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)
                .regions[record.id]
        )

        func unit(_ tags: [String], topic: String? = "Bakteriyoloji") -> KnowledgeUnit {
            BackupPageInstaller.unit(
                on: region, subject: "Mikrobiyoloji", topic: topic, claim: "★ Brucella",
                tags: tags, createdAt: captured, context: context
            )
        }
        let a = unit([])
        let b = unit([])
        let tagged = unit(["zoonoz"])
        let otherTopic = unit([], topic: "İmmünoloji")

        XCTAssertIdentical(a, b)
        XCTAssertFalse(a === tagged, "farklı etiketli kayıt başka birinin etiketini almamalı")
        XCTAssertFalse(a === otherTopic)
        XCTAssertEqual(tagged.tags, ["zoonoz"])
        XCTAssertEqual(region.knowledgeUnits.count, 3)
        XCTAssertTrue(region.knowledgeUnits.allSatisfy { $0.region === region })
    }

    // MARK: Failure leaves nothing on disk

    /// A write that fails half-way removes the images already written before
    /// the error reaches the restore, which only has a context to roll back.
    func testAFailedImageWriteRemovesTheImagesWrittenBeforeIt() throws {
        let good = pageRecord()
        let blocked = pageRecord()
        // A directory where the second image's file must go makes that write
        // fail — the nearest thing to a full disk a test can arrange.
        let blockedPath = try store.store(Data("x".utf8), id: blocked.id)
        try store.remove(relativePath: blockedPath)
        try FileManager.default.createDirectory(
            at: store.url(forRelativePath: blockedPath).appendingPathComponent("engel"),
            withIntermediateDirectories: true
        )
        let plan = BackupRestorer.plan(
            records: [cardRecord(pageId: good.id), cardRecord(pageId: blocked.id)],
            pages: [good, blocked],
            existingIds: []
        )
        XCTAssertEqual(plan.pagesToInsert.map(\.id), [good.id, blocked.id])

        XCTAssertThrowsError(
            try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)
        )
        let goodPath = "\(good.id.uuidString.prefix(2))/\(good.id.uuidString)-original.jpg"
        XCTAssertFalse(store.exists(relativePath: goodPath), "yarım geri yükleme diskte yetim JPEG bırakmamalı")
    }

    /// The save-failed half: what the restore calls after its rollback.
    func testDiscardRemovesEveryWrittenImage() throws {
        let pages = [pageRecord(), pageRecord()]
        let plan = BackupRestorer.plan(
            records: pages.map { cardRecord(pageId: $0.id) },
            pages: pages,
            existingIds: []
        )
        let installed = try BackupPageInstaller.install(plan, imageStore: store, context: context, schema: schema)
        XCTAssertEqual(storedFileCount(), 2)
        context.rollback()

        BackupPageInstaller.discard(installed.writtenImagePaths, imageStore: store)
        XCTAssertEqual(storedFileCount(), 0)
        XCTAssertTrue(try context.fetch(FetchDescriptor<CapturedPage>()).isEmpty)
    }
}
