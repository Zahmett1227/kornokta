import XCTest
@testable import CizgiCore

/// Backup that can actually be restored (§24.6), duplicate-page recognition
/// (§17, §21.1) and reminders that tell the truth (§5.4, §6.7).
///
/// All three were fields or promises the code carried without keeping: an
/// encoder with no decoder, a `perceptualHash` column nothing ever wrote, and a
/// reminder that fired whether or not anything was due.
final class BackupRestoreTests: XCTestCase {
    private let exportedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func record(
        id: UUID = UUID(),
        front: String = "Soru",
        tags: [String] = ["Farmakoloji"],
        reviews: [BackupExporter.ReviewRecord] = [],
        pageId: UUID? = nil
    ) -> BackupExporter.CardRecord {
        BackupExporter.CardRecord(
            id: id,
            type: "direct_recall",
            front: front,
            back: "Cevap",
            explanation: nil,
            sourceQuote: nil,
            subject: "Farmakoloji",
            status: "active",
            dueDate: exportedAt,
            stability: 3.2,
            difficulty: 5.1,
            reviewCount: 4,
            lapseCount: 1,
            createdAt: exportedAt.addingTimeInterval(-86_400),
            updatedAt: exportedAt,
            lastReviewedAt: exportedAt.addingTimeInterval(-3600),
            tags: tags,
            canonicalClaim: "Sayfada okunan metin",
            reviews: reviews,
            pageId: pageId
        )
    }

    private func page(id: UUID = UUID(), usable: Bool = true) -> BackupExporter.PageRecord {
        BackupExporter.PageRecord(
            id: id,
            jpegData: usable ? TestJPEG.tiny : Data(),
            captureDate: exportedAt,
            subject: "Farmakoloji",
            readText: "Sayfada okunan metin"
        )
    }

    private func review() -> BackupExporter.ReviewRecord {
        BackupExporter.ReviewRecord(
            reviewedAt: exportedAt.addingTimeInterval(-3600),
            rating: "good",
            responseTimeMs: 4200,
            scheduledDays: 3,
            elapsedDays: 1,
            stabilityBefore: 2.0,
            stabilityAfter: 3.2,
            difficultyBefore: 5.0,
            difficultyAfter: 5.1,
            deviceTimeZone: "Europe/Istanbul"
        )
    }

    // MARK: Round trip

    func testABackupSurvivesEncodingAndDecoding() throws {
        let cards = [record(front: "Bir"), record(front: "İki")]
        let restored = try BackupExporter.decode(
            try BackupExporter.encode(cards: cards, exportedAt: exportedAt)
        )
        XCTAssertEqual(restored.formatVersion, BackupExporter.formatVersion)
        XCTAssertEqual(restored.exportedAt, exportedAt)
        XCTAssertEqual(Set(restored.cards.map(\.front)), ["Bir", "İki"])
    }

    /// The whole reason for version 2. Review history is the only record of how
    /// this user's memory behaved, and the input FSRS weight optimisation needs
    /// — leaving it out meant it could never leave the phone.
    func testReviewHistoryAndTagsSurviveTheRoundTrip() throws {
        let card = record(reviews: [review(), review()])
        let restored = try BackupExporter.decode(
            try BackupExporter.encode(cards: [card], exportedAt: exportedAt)
        )
        let decoded = try XCTUnwrap(restored.cards.first)
        XCTAssertEqual(decoded.reviews.count, 2)
        XCTAssertEqual(decoded.reviews.first?.responseTimeMs, 4200)
        XCTAssertEqual(decoded.reviews.first?.deviceTimeZone, "Europe/Istanbul")
        XCTAssertEqual(decoded.tags, ["Farmakoloji"])
        XCTAssertEqual(decoded.canonicalClaim, "Sayfada okunan metin")
        XCTAssertEqual(decoded.createdAt, exportedAt.addingTimeInterval(-86_400))
    }

    /// A version 1 file has none of the keys added since. It has to restore as
    /// the subset it always was rather than failing — that is the only backup
    /// anyone who used the old build has.
    func testAVersionOneFileStillRestores() throws {
        let legacy = """
        {
          "formatVersion": 1,
          "exportedAt": "2026-02-02T03:20:00Z",
          "cards": [
            {
              "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
              "type": "direct_recall",
              "front": "Eski soru",
              "back": "Eski cevap",
              "status": "active",
              "dueDate": "2026-02-02T03:20:00Z",
              "stability": 1.5,
              "difficulty": 5.0,
              "reviewCount": 2,
              "lapseCount": 0
            }
          ]
        }
        """.data(using: .utf8)!

        let restored = try BackupExporter.decode(legacy)
        XCTAssertEqual(restored.formatVersion, 1)
        let card = try XCTUnwrap(restored.cards.first)
        XCTAssertEqual(card.front, "Eski soru")
        XCTAssertEqual(card.reviews, [])
        XCTAssertEqual(card.tags, [])
        XCTAssertNil(card.canonicalClaim)
    }

    func testAFileFromANewerBuildIsRefusedRatherThanPartlyRead() {
        let future = """
        {"formatVersion": 99, "exportedAt": "2026-02-02T03:20:00Z", "cards": []}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try BackupExporter.decode(future)) { error in
            XCTAssertEqual(error as? BackupExporter.BackupError, .unsupportedVersion(99))
        }
    }

    func testGarbageIsReportedAsUnreadable() {
        let garbage = Data("bu bir yedek değil".utf8)
        XCTAssertThrowsError(try BackupExporter.decode(garbage)) { error in
            guard case .unreadable = (error as? BackupExporter.BackupError) else {
                return XCTFail("okunamaz dosya bildirilmemeli")
            }
        }
    }

    // MARK: Restore planning

    /// Additive by design. A restore onto a device used since the backup was
    /// taken must not roll back newer review history — losing a week of
    /// scheduling to a restore meant to *prevent* loss is the worst outcome.
    func testAnExistingCardIsSkippedNotOverwritten() {
        let existing = UUID()
        let fresh = UUID()
        let plan = BackupRestorer.plan(
            records: [record(id: existing), record(id: fresh)],
            existingIds: [existing]
        )
        XCTAssertEqual(plan.toInsert.map(\.id), [fresh])
        XCTAssertEqual(plan.skipped, [existing])
    }

    func testRestoringIntoAnEmptyStoreInsertsEverything() {
        let plan = BackupRestorer.plan(records: [record(), record(), record()], existingIds: [])
        XCTAssertEqual(plan.toInsert.count, 3)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertFalse(plan.isEmpty)
    }

    /// An untrusted file with a repeated id should restore what it can rather
    /// than throw, and must not insert the same card twice.
    func testADuplicateIdInsideOneFileCollapses() {
        let id = UUID()
        let plan = BackupRestorer.plan(records: [record(id: id), record(id: id)], existingIds: [])
        XCTAssertEqual(plan.toInsert.count, 1)
        XCTAssertEqual(plan.skipped, [id])
    }

    func testRestoringTheSameFileTwiceChangesNothingTheSecondTime() {
        let records = [record(), record()]
        let first = BackupRestorer.plan(records: records, existingIds: [])
        let second = BackupRestorer.plan(records: records, existingIds: Set(first.toInsert.map(\.id)))
        XCTAssertTrue(second.isEmpty)
    }

    // MARK: Restore planning — pages (version 9, docs/ADR-011)

    /// (a) Cards naming a page in the file go in with it, and the page is
    /// planned once however many cards share it.
    func testCardsAndTheirPageArePlannedTogether() {
        let pageId = UUID()
        let first = record(pageId: pageId)
        let second = record(pageId: pageId)
        let plan = BackupRestorer.plan(
            records: [first, second],
            pages: [page(id: pageId)],
            existingIds: []
        )
        XCTAssertEqual(plan.toInsert.count, 2)
        XCTAssertEqual(plan.pagesToInsert.map(\.id), [pageId])
        XCTAssertEqual(plan.pageLinks, [first.id: pageId, second.id: pageId])
        XCTAssertEqual(plan.linkedPageCount, 1)
        XCTAssertTrue(plan.cardsWithMissingPage.isEmpty)
    }

    /// (b) A dangling reference costs the card its photo, not the restore.
    func testAPageIdWithNoPageInTheFileStillInsertsTheCard() {
        let card = record(pageId: UUID())
        let plan = BackupRestorer.plan(records: [card], pages: [page()], existingIds: [])
        XCTAssertEqual(plan.toInsert.map(\.id), [card.id])
        XCTAssertTrue(plan.pagesToInsert.isEmpty, "hiçbir karta bağlı olmayan sayfa kurulmamalı")
        XCTAssertTrue(plan.pageLinks.isEmpty)
        XCTAssertEqual(plan.cardsWithMissingPage, [card.id])
    }

    /// A page whose image would not decode is the same as no page: its cards
    /// go in photoless and are counted, and no page is built for them.
    func testAPageWithAnUnusableImageIsCountedAsMissing() {
        let pageId = UUID()
        let card = record(pageId: pageId)
        let plan = BackupRestorer.plan(
            records: [card],
            pages: [page(id: pageId, usable: false)],
            existingIds: []
        )
        XCTAssertEqual(plan.toInsert.count, 1)
        XCTAssertTrue(plan.pagesToInsert.isEmpty)
        XCTAssertEqual(plan.cardsWithMissingPage, [card.id])
    }

    /// A repeated page id with a broken image first and a good one second still
    /// gets its photo — the file is untrusted; restore what it can.
    func testTheFirstUsableCopyOfARepeatedPageWins() {
        let pageId = UUID()
        let card = record(pageId: pageId)
        let good = page(id: pageId)
        let plan = BackupRestorer.plan(
            records: [card],
            pages: [page(id: pageId, usable: false), good, page(id: pageId)],
            existingIds: []
        )
        XCTAssertEqual(plan.pagesToInsert, [good])
        XCTAssertEqual(plan.pageLinks[card.id], pageId)
    }

    /// (c) Every card of a page already on the device: the page is not built,
    /// so no `CapturedPage` is left with nothing under it.
    func testAPageWhoseCardsAreAllHereAlreadyIsNotPlanned() {
        let pageId = UUID()
        let cards = [record(pageId: pageId), record(pageId: pageId)]
        let plan = BackupRestorer.plan(
            records: cards,
            pages: [page(id: pageId)],
            existingIds: Set(cards.map(\.id))
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.pagesToInsert.isEmpty)
        XCTAssertTrue(plan.cardsWithMissingPage.isEmpty)
    }

    /// Only the cards still going in keep a page alive: one of two here.
    func testAPageIsPlannedForItsRemainingNewCardOnly() {
        let pageId = UUID()
        let present = record(pageId: pageId)
        let fresh = record(pageId: pageId)
        let plan = BackupRestorer.plan(
            records: [present, fresh],
            pages: [page(id: pageId)],
            existingIds: [present.id]
        )
        XCTAssertEqual(plan.pagesToInsert.map(\.id), [pageId])
        XCTAssertEqual(plan.pageLinks, [fresh.id: pageId])
    }

    /// (d) A page the device already has is not built or written again, but a
    /// new card naming it is still linked to it.
    func testAPageAlreadyOnTheDeviceIsLinkedNotRebuilt() {
        let pageId = UUID()
        let card = record(pageId: pageId)
        let plan = BackupRestorer.plan(
            records: [card],
            pages: [page(id: pageId)],
            existingIds: [],
            existingPageIds: [pageId]
        )
        XCTAssertTrue(plan.pagesToInsert.isEmpty)
        XCTAssertEqual(plan.pageLinks, [card.id: pageId])
        XCTAssertEqual(plan.linkedPageCount, 1)
        XCTAssertTrue(plan.cardsWithMissingPage.isEmpty)
    }

    /// The owner's second gate: the same v9 file twice builds nothing new.
    func testRestoringAFileWithPagesTwiceBuildsNothingTheSecondTime() {
        let pageId = UUID()
        let records = [record(pageId: pageId), record()]
        let pages = [page(id: pageId)]
        let first = BackupRestorer.plan(records: records, pages: pages, existingIds: [])
        let second = BackupRestorer.plan(
            records: records,
            pages: pages,
            existingIds: Set(first.toInsert.map(\.id)),
            existingPageIds: Set(first.pagesToInsert.map(\.id))
        )
        XCTAssertTrue(second.isEmpty)
        XCTAssertTrue(second.pagesToInsert.isEmpty)
    }

    /// A card with no `pageId` plans exactly as it did in version 8, whatever
    /// pages the file carries.
    func testACardWithoutAPageIdIsUntouchedByPages() {
        let card = record()
        let plan = BackupRestorer.plan(records: [card], pages: [page()], existingIds: [])
        XCTAssertEqual(plan, RestorePlan(toInsert: [card], skipped: []))
    }

    /// A removed-deck card never keeps a page alive: it is not going in.
    func testAConceptCardDoesNotPlanItsPage() {
        let pageId = UUID()
        let concept = record(tags: [ConceptDeckLegacy.tag], pageId: pageId)
        let plan = BackupRestorer.plan(records: [concept], pages: [page(id: pageId)], existingIds: [])
        XCTAssertEqual(plan.skippedLegacyConcept, [concept.id])
        XCTAssertTrue(plan.pagesToInsert.isEmpty)
        XCTAssertTrue(plan.cardsWithMissingPage.isEmpty)
    }

    // MARK: Restore planning — from a file (Codex, PR #50)

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cizgi-yedek-\(UUID().uuidString).json")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The detached half of a restore plans exactly what planning the decoded
    /// contents would.
    func testPlanningAFileMatchesPlanningItsContents() throws {
        let pageId = UUID()
        let existing = UUID()
        let records = [record(pageId: pageId), record(id: existing), record(pageId: UUID())]
        let pages = [page(id: pageId)]
        let url = try temporaryFile(try BackupExporter.encode(cards: records, pages: pages, exportedAt: exportedAt))

        let fromFile = try BackupRestorer.plan(fileAt: url, existingIds: [existing], existingPageIds: [])
        let decoded = try BackupExporter.decode(try Data(contentsOf: url))
        XCTAssertEqual(
            fromFile,
            BackupRestorer.plan(records: decoded.cards, pages: decoded.pages, existingIds: [existing])
        )
        XCTAssertEqual(fromFile.pagesToInsert.map(\.id), [pageId])
        XCTAssertEqual(fromFile.cardsWithMissingPage.count, 1)
    }

    /// Past the limit a restore would be ended by the system mid-way; it is
    /// refused up front, with the way out in the message.
    func testAFileOverTheLimitIsRefusedWithAWayOut() throws {
        let data = try BackupExporter.encode(cards: [record()], exportedAt: exportedAt)
        let url = try temporaryFile(data)

        XCTAssertThrowsError(
            try BackupRestorer.plan(fileAt: url, existingIds: [], existingPageIds: [], maxBytes: data.count - 1)
        ) { error in
            XCTAssertEqual(
                error as? BackupExporter.BackupError,
                .tooLarge(bytes: data.count, limit: data.count - 1)
            )
        }
        XCTAssertNoThrow(
            try BackupRestorer.plan(fileAt: url, existingIds: [], existingPageIds: [], maxBytes: data.count)
        )

        let megabyte = 1024 * 1024
        let message = try XCTUnwrap(
            BackupExporter.BackupError.tooLarge(bytes: 300 * megabyte, limit: BackupRestorer.maxFileBytes)
                .errorDescription
        )
        XCTAssertTrue(message.contains("300 MB"))
        XCTAssertTrue(message.contains("256 MB"))
        XCTAssertTrue(message.contains("böl"))
    }

    // MARK: Perceptual hash

    /// A gradient: every pixel is brighter than the one to its left, so every
    /// comparison bit is 0. Any different structure must produce different bits.
    private func gradient(width: Int = 90, height: Int = 80) -> [UInt8] {
        (0..<(width * height)).map { UInt8(($0 % width) * 255 / max(1, width - 1)) }
    }

    private func inverted(width: Int = 90, height: Int = 80) -> [UInt8] {
        gradient(width: width, height: height).map { 255 - $0 }
    }

    func testTheSameImageHashesTheSame() {
        let a = PerceptualHasher.hash(grayscale: gradient(), width: 90, height: 80)
        let b = PerceptualHasher.hash(grayscale: gradient(), width: 90, height: 80)
        XCTAssertEqual(a, b)
        XCTAssertEqual(PerceptualHasher.distance(try! XCTUnwrap(a), try! XCTUnwrap(b)), 0)
    }

    /// Structure, not brightness: a mirrored gradient flips every comparison.
    func testAStructurallyOppositeImageIsFarAway() throws {
        let a = try XCTUnwrap(PerceptualHasher.hash(grayscale: gradient(), width: 90, height: 80))
        let b = try XCTUnwrap(PerceptualHasher.hash(grayscale: inverted(), width: 90, height: 80))
        XCTAssertEqual(PerceptualHasher.distance(a, b), 64)
        XCTAssertFalse(PerceptualHasher.isLikelyDuplicate(a, b))
    }

    /// Difference hashing keys on neighbour comparisons, so a uniform lighting
    /// change — the difference between two shots of one page — moves nothing.
    func testAUniformBrightnessShiftDoesNotChangeTheHash() throws {
        let darker = gradient().map { UInt8(max(0, Int($0) - 40)) }
        let a = try XCTUnwrap(PerceptualHasher.hash(grayscale: gradient(), width: 90, height: 80))
        let b = try XCTUnwrap(PerceptualHasher.hash(grayscale: darker, width: 90, height: 80))
        XCTAssertTrue(PerceptualHasher.isLikelyDuplicate(a, b))
    }

    func testAnImageTooSmallToSampleHasNoHash() {
        XCTAssertNil(PerceptualHasher.hash(grayscale: [1, 2, 3, 4], width: 2, height: 2))
        XCTAssertNil(PerceptualHasher.hash(grayscale: [], width: 90, height: 80))
    }

    func testAHashSurvivesTheStringFormItIsStoredIn() throws {
        let hash = try XCTUnwrap(PerceptualHasher.hash(grayscale: gradient(), width: 90, height: 80))
        XCTAssertEqual(hash.stringValue.count, 16)
        XCTAssertEqual(PerceptualHash(stringValue: hash.stringValue), hash)
        XCTAssertNil(PerceptualHash(stringValue: "kısa"))
        XCTAssertNil(PerceptualHash(stringValue: "zzzzzzzzzzzzzzzz"))
    }

    func testTheNearestCandidateWinsAndFarOnesAreIgnored() {
        let base = PerceptualHash(bits: 0)
        let near = PerceptualHash(bits: 0b11)                    // distance 2
        let nearer = PerceptualHash(bits: 0b1)                   // distance 1
        let far = PerceptualHash(bits: UInt64.max)               // distance 64

        let match = PerceptualHasher.nearestDuplicate(
            to: base,
            among: [(id: "near", hash: near), (id: "far", hash: far), (id: "nearer", hash: nearer)]
        )
        XCTAssertEqual(match?.id, "nearer")
        XCTAssertEqual(match?.distance, 1)

        XCTAssertNil(PerceptualHasher.nearestDuplicate(to: base, among: [(id: "far", hash: far)]))
    }

    // MARK: Batch de-duplication

    private func hashes(_ bits: [UInt64?]) -> [PerceptualHash?] {
        bits.map { $0.map(PerceptualHash.init(bits:)) }
    }

    /// The gap Codex found: comparing only against stored pages let a page
    /// photographed twice in one scan through twice — two card sets, two
    /// charges — because neither copy was in the store yet.
    func testTheSamePageTwiceInOneScanIsCaughtEvenWhenItIsBrandNew() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: hashes([0b1010, 0b1010]),
            storedHashes: []
        )
        XCTAssertEqual(duplicates, [1], "ilk kopya tutulmalı, ikincisi elenmeli")
    }

    func testThreeCopiesYieldOnePageAndTwoSkips() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: hashes([0b1010, 0b1010, 0b1010]),
            storedHashes: []
        )
        XCTAssertEqual(duplicates, [1, 2])
    }

    func testAnAlreadyStoredPageIsStillCaught() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: hashes([0b1010, UInt64.max]),
            storedHashes: [PerceptualHash(bits: 0b1010)]
        )
        XCTAssertEqual(duplicates, [0])
    }

    func testDistinctPagesInOneScanAllSurvive() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: hashes([0, UInt64.max, 0x00FF_00FF_00FF_00FF]),
            storedHashes: []
        )
        XCTAssertTrue(duplicates.isEmpty)
    }

    /// A skipped copy must not become the thing later images are compared
    /// against, or the original would end up shadowed by its own duplicate.
    func testASkippedCopyDoesNotShadowTheOriginal() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: hashes([0b1, 0b1, 0b1]),
            storedHashes: []
        )
        XCTAssertEqual(duplicates, [1, 2])
    }

    /// Unreadable is not the same as "seen before"; losing a capture to a
    /// decoder's bad day would be the worse failure (§21.2).
    func testAnUnhashableImageIsNeverCalledADuplicate() {
        let duplicates = PerceptualHasher.duplicateIndices(
            hashes: [nil, nil],
            storedHashes: [PerceptualHash(bits: 0)]
        )
        XCTAssertTrue(duplicates.isEmpty)
    }

    // MARK: Reminders

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Istanbul")!
        return calendar
    }

    /// 2026-02-02, 09:00 Istanbul.
    private var morning: Date {
        calendar.date(from: DateComponents(year: 2026, month: 2, day: 2, hour: 9))!
    }

    /// The fault this replaces: the old trigger fired every day regardless.
    func testNoReminderIsScheduledForADayWithNothingDue() {
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: [], hour: 20, from: morning, calendar: calendar
        )
        XCTAssertTrue(reminders.isEmpty)
    }

    func testAReminderCarriesTheCountThatWillBeDueByThen() throws {
        let tonight = calendar.date(from: DateComponents(year: 2026, month: 2, day: 2, hour: 20))!
        let dueDates = [
            morning.addingTimeInterval(-3600),   // already due
            tonight.addingTimeInterval(-60),     // due just before the reminder
            tonight.addingTimeInterval(3600),    // not yet — must not be counted tonight
        ]
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: dueDates, hour: 20, from: morning, days: 1, calendar: calendar
        )
        let first = try XCTUnwrap(reminders.first)
        XCTAssertEqual(first.fireDate, tonight)
        XCTAssertEqual(first.dueCount, 2)
        XCTAssertEqual(first.body, "Günlük tekrarlarını tamamla — 2 kart bekliyor.")
    }

    /// The owner's rule, in their words: every day, unless today's reviews are
    /// already done (2026-09-14). "Done" is not a flag anywhere — it is what
    /// grading does to due dates. A finished session pushes every card past
    /// tonight, the app reschedules, and tonight's slot finds nothing to count.
    func testFinishingTodaysReviewsSilencesTonight() {
        let dueThisMorning = [morning.addingTimeInterval(-3600), morning.addingTimeInterval(-60)]
        let before = ReviewReminderPlanner.reminders(
            dueDates: dueThisMorning, hour: 20, from: morning, days: 1, calendar: calendar
        )
        XCTAssertEqual(before.count, 1, "tekrar yapılmadan önce bu akşam hatırlatma olmalı")

        // The same two cards after grading: FSRS moved them to later days.
        let afterGrading = [morning.addingTimeInterval(2 * 86_400), morning.addingTimeInterval(4 * 86_400)]
        let after = ReviewReminderPlanner.reminders(
            dueDates: afterGrading, hour: 20, from: morning, days: 1, calendar: calendar
        )
        XCTAssertTrue(after.isEmpty, "tekrarlar bitince bu akşam sessiz kalmalı")
    }

    /// One reminder a day for two weeks when every day has something due.
    func testTheHorizonIsTwoWeeks() {
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: [morning.addingTimeInterval(-60)], hour: 20, from: morning, calendar: calendar
        )
        XCTAssertEqual(ReviewReminderPlanner.horizonDays, 14)
        XCTAssertEqual(reminders.count, 14)
    }

    /// Opening the app after tonight's slot has passed must not schedule one in
    /// the past — it would fire instantly or be dropped.
    func testTodaysSlotIsSkippedOnceItHasPassed() {
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 2, day: 2, hour: 22))!
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: [morning], hour: 20, from: lateEvening, days: 2, calendar: calendar
        )
        XCTAssertEqual(reminders.count, 1)
        XCTAssertEqual(
            calendar.component(.day, from: reminders[0].fireDate), 3,
            "geçmiş saat atlanıp ertesi güne geçilmeli"
        )
    }

    func testTheCountGrowsAcrossTheHorizonAsMoreCardsFallDue() {
        let dueDates = (0..<5).map { morning.addingTimeInterval(Double($0) * 86_400) }
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: dueDates, hour: 20, from: morning, days: 3, calendar: calendar
        )
        XCTAssertEqual(reminders.map(\.dueCount), [1, 2, 3])
    }

    func testAnOutOfRangeHourIsClampedRatherThanDropped() throws {
        let reminders = ReviewReminderPlanner.reminders(
            dueDates: [morning], hour: 99, from: morning, days: 1, calendar: calendar
        )
        let first = try XCTUnwrap(reminders.first)
        XCTAssertEqual(calendar.component(.hour, from: first.fireDate), 23)
    }

    func testTheBadgeCountsWhatIsDueNowNotLaterToday() {
        let dueDates = [
            morning.addingTimeInterval(-1),
            morning.addingTimeInterval(3600),
        ]
        XCTAssertEqual(ReviewReminderPlanner.badgeCount(dueDates: dueDates, now: morning), 1)
    }
}
