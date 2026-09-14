import XCTest
@testable import CizgiCore

final class BackupExporterTests: XCTestCase {
    func testExportIsVersionedDeterministicAndContainsNoImagePath() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let record = BackupExporter.CardRecord(
            id: id, type: "direct_recall", front: "Soru", back: "Yanıt",
            explanation: nil, sourceQuote: "Kaynak", subject: "Tıp",
            status: "active", dueDate: Date(timeIntervalSince1970: 0),
            stability: 1, difficulty: 5, reviewCount: 2, lapseCount: 0
        )
        let data = try BackupExporter.encode(cards: [record], exportedAt: Date(timeIntervalSince1970: 0))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Tied to the exporter's own constant, not a literal: this assertion's
        // job is "the file is versioned", and a hardcoded number just goes red
        // on every version bump (it sat failing at 1 while the exporter was
        // already at 3, and no CI ran Swift to notice).
        XCTAssertTrue(text.contains("\"formatVersion\" : \(BackupExporter.formatVersion)"))
        XCTAssertTrue(text.contains("\"front\" : \"Soru\""))
        XCTAssertFalse(text.contains("imagePath"))
        XCTAssertEqual(data, try BackupExporter.encode(cards: [record], exportedAt: Date(timeIntervalSince1970: 0)))
    }

    /// Version 4: without this the classification survives export but not
    /// restore, and a recovered deck lands entirely in "Konusuz" — the topic
    /// filters and the exercise mode then no longer reproduce what was backed
    /// up (Codex, PR #32).
    func testTopicSurvivesAFullExportRestoreRoundTrip() throws {
        let record = BackupExporter.CardRecord(
            id: UUID(), type: "direct_recall", front: "Soru", back: "Yanıt",
            explanation: nil, sourceQuote: nil, subject: "Patoloji",
            status: "active", dueDate: Date(timeIntervalSince1970: 0),
            stability: 1, difficulty: 5, reviewCount: 2, lapseCount: 0,
            topic: "İnflamasyon"
        )
        let data = try BackupExporter.encode(cards: [record], exportedAt: Date(timeIntervalSince1970: 0))
        let restored = try BackupExporter.decode(data)

        XCTAssertEqual(restored.cards.first?.topic, "İnflamasyon")
        XCTAssertEqual(restored.cards.first?.subject, "Patoloji")
    }

    /// Version 6 (docs/ADR-008): exported as already-finalized, not
    /// recomputed on the way back in — `fesInitializedAt` surviving the round
    /// trip is what tells the receiving device's backfill migration to leave
    /// this card alone.
    func testFesRecordSurvivesAFullExportRestoreRoundTrip() throws {
        let initializedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = BackupExporter.CardRecord(
            id: UUID(), type: "direct_recall", front: "Soru", back: "Yanıt",
            explanation: nil, sourceQuote: nil, subject: "Patoloji",
            status: "active", dueDate: Date(timeIntervalSince1970: 0),
            stability: 1, difficulty: 5, reviewCount: 2, lapseCount: 0,
            fesScore: 5, fesNegativeCount: 3, fesInitializedAt: initializedAt
        )
        let data = try BackupExporter.encode(cards: [record], exportedAt: Date(timeIntervalSince1970: 0))
        let restored = try BackupExporter.decode(data)

        XCTAssertEqual(restored.cards.first?.fesScore, 5)
        XCTAssertEqual(restored.cards.first?.fesNegativeCount, 3)
        XCTAssertEqual(restored.cards.first?.fesInitializedAt, initializedAt)
    }

    func testAPreFesBackupStillDecodesWithFesDefaults() throws {
        // A version 5 file has none of the three FES keys. Defaulting to
        // "never initialized" is correct, not just tolerated: it is exactly
        // the signal that lets `FesBackfillMigration` attempt a best-effort
        // replay from whatever `ReviewLog` history the same file restores.
        let json = """
        {"formatVersion":5,"exportedAt":"1970-01-01T00:00:00Z","cards":[{
          "id":"00000000-0000-0000-0000-000000000001","type":"direct_recall",
          "front":"Soru","back":"Yanıt","subject":"Patoloji","status":"active",
          "dueDate":"1970-01-01T00:00:00Z","stability":1,"difficulty":5,
          "reviewCount":0,"lapseCount":0
        }]}
        """
        let restored = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(restored.cards.first?.fesScore, 0)
        XCTAssertEqual(restored.cards.first?.fesNegativeCount, 0)
        XCTAssertNil(restored.cards.first?.fesInitializedAt)
    }

    func testAPreTopicBackupStillDecodesWithNoTopic() throws {
        // A version 3 file has no `topic` key at all. It has to restore as the
        // subset it always was, not fail — the same contract every field added
        // since version 1 follows.
        let json = """
        {"formatVersion":3,"exportedAt":"1970-01-01T00:00:00Z","cards":[{
          "id":"00000000-0000-0000-0000-000000000001","type":"direct_recall",
          "front":"Soru","back":"Yanıt","subject":"Patoloji","status":"active",
          "dueDate":"1970-01-01T00:00:00Z","stability":1,"difficulty":5,
          "reviewCount":0,"lapseCount":0
        }]}
        """
        let restored = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(restored.cards.count, 1)
        XCTAssertNil(restored.cards.first?.topic)
        XCTAssertEqual(restored.cards.first?.subject, "Patoloji")
    }

    // MARK: - Version 8: the concept deck is gone

    private func record(
        _ front: String,
        tags: [String] = [],
        status: String = "active",
        id: UUID = UUID()
    ) -> BackupExporter.CardRecord {
        BackupExporter.CardRecord(
            id: id, type: "direct_recall", front: front, back: "Yanıt",
            explanation: nil, sourceQuote: nil, subject: "Farmakoloji",
            status: status, dueDate: Date(timeIntervalSince1970: 0),
            stability: 1, difficulty: 5, reviewCount: 0, lapseCount: 0,
            tags: tags
        )
    }

    /// The owner's real file: a v7 backup holding the photographed deck *and*
    /// the concept pack. The key it carries is ignored, the file still decodes,
    /// and the concept records are recognised by the importer's tag.
    func testAVersion7FileWithConceptCardsStillDecodes() throws {
        let json = """
        {"formatVersion":7,"exportedAt":"1970-01-01T00:00:00Z","cards":[
          {"id":"00000000-0000-0000-0000-00000000000A","type":"direct_recall",
           "front":"Çekim","back":"Yanıt","subject":"Patoloji","status":"active",
           "dueDate":"1970-01-01T00:00:00Z","stability":1,"difficulty":5,
           "reviewCount":0,"lapseCount":0,"tags":["solunum"],"collection":"capture"},
          {"id":"00000000-0000-0000-0000-00000000000B","type":"direct_recall",
           "front":"Kavram","back":"Yanıt","subject":"Farmakoloji","status":"active",
           "dueDate":"1970-01-01T00:00:00Z","stability":1,"difficulty":5,
           "reviewCount":0,"lapseCount":0,"tags":["glibenklamid","kavram-paketi"],
           "collection":"concept","fesScore":4}
        ]}
        """
        let backup = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(backup.cards.count, 2)

        let plan = BackupRestorer.plan(records: backup.cards, existingIds: [])
        XCTAssertEqual(plan.toInsert.map(\.front), ["Çekim"])
        XCTAssertEqual(plan.skippedLegacyConcept, [UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!])
        XCTAssertTrue(plan.skipped.isEmpty, "kavram kartı 'zaten vardı' sayılmamalı")
    }

    /// A concept card that happens to share an id with a card on the device is
    /// still reported as a concept card — never as "already here", which would
    /// claim the device holds it.
    func testAConceptCardIsNeverCountedAsAlreadyHere() {
        let id = UUID()
        let plan = BackupRestorer.plan(
            records: [record("Kavram", tags: [ConceptDeckLegacy.tag], id: id)],
            existingIds: [id]
        )
        XCTAssertEqual(plan.skippedLegacyConcept, [id])
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.isEmpty)
    }

    /// Cards imported after the queue existed were `queued`; the status alone
    /// is enough to leave such a record out.
    func testAQueuedRecordIsLeftOutEvenWithoutTheTag() {
        let plan = BackupRestorer.plan(records: [record("Kuyrukta", status: "queued")], existingIds: [])
        XCTAssertEqual(plan.skippedLegacyConcept.count, 1)
        XCTAssertTrue(plan.toInsert.isEmpty)
    }

    /// What the owner asked for in so many words: a backup taken from now on
    /// holds nothing about the removed deck — not even the empty field.
    func testAVersion8FileHasNoCollectionKey() throws {
        let data = try BackupExporter.encode(cards: [record("Çekim")], exportedAt: Date(timeIntervalSince1970: 0))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cards = try XCTUnwrap(object["cards"] as? [[String: Any]])
        XCTAssertNil(cards.first?["collection"])
    }

    /// Guards the version constant itself: a file from a newer build must be
    /// refused rather than restored as a lossy subset.
    func testTheFormatVersionIsNine() {
        XCTAssertEqual(BackupExporter.formatVersion, 9)
        XCTAssertNoThrow(try BackupExporter.decode(Data(
            #"{"formatVersion":8,"exportedAt":"1970-01-01T00:00:00Z","cards":[]}"#.utf8
        )))
        XCTAssertThrowsError(try BackupExporter.decode(Data(
            #"{"formatVersion":10,"exportedAt":"1970-01-01T00:00:00Z","cards":[]}"#.utf8
        )))
    }

    // MARK: - Version 9: page photographs (docs/ADR-011)

    /// The smallest real JPEG: what the task's example file carries.
    static let tinyJPEGBase64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k="

    func testPagesAndPageIdsSurviveTheRoundTrip() throws {
        let pageId = UUID()
        let page = BackupExporter.PageRecord(
            id: pageId,
            jpegData: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]),
            captureDate: Date(timeIntervalSince1970: 1_700_000_000),
            subject: "Mikrobiyoloji",
            readText: "★ Brucella",
            pageLabel: "s.126"
        )
        let card = BackupExporter.CardRecord(
            id: UUID(), type: "direct_recall", front: "Soru", back: "Yanıt",
            explanation: nil, sourceQuote: nil, subject: "Mikrobiyoloji",
            status: "active", dueDate: Date(timeIntervalSince1970: 0),
            stability: 0, difficulty: 0, reviewCount: 0, lapseCount: 0,
            pageId: pageId
        )
        let data = try BackupExporter.encode(cards: [card], pages: [page], exportedAt: Date(timeIntervalSince1970: 0))
        let restored = try BackupExporter.decode(data)

        XCTAssertEqual(restored.pages, [page])
        XCTAssertEqual(restored.cards.first?.pageId, pageId)
        XCTAssertTrue(try XCTUnwrap(restored.pages.first).hasUsableImage)
    }

    /// The file the app writes: no pages, no page ids. Neither key may appear,
    /// so the export has exactly the shape a version 8 export had.
    func testAnExportWithoutPagesWritesNeitherNewKey() throws {
        let data = try BackupExporter.encode(cards: [record("Çekim")], exportedAt: Date(timeIntervalSince1970: 0))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["pages"])
        let cards = try XCTUnwrap(object["cards"] as? [[String: Any]])
        XCTAssertNil(cards.first?["pageId"])
        XCTAssertEqual(Set(object.keys), ["formatVersion", "exportedAt", "cards"])
    }

    func testAVersion9FileWithoutPagesDecodes() throws {
        let json = """
        {"formatVersion":9,"exportedAt":"1970-01-01T00:00:00Z","cards":[{
          "id":"00000000-0000-0000-0000-000000000001","type":"direct_recall",
          "front":"Soru","back":"Yanıt","status":"active",
          "dueDate":"1970-01-01T00:00:00Z","stability":1,"difficulty":5,
          "reviewCount":0,"lapseCount":0
        }]}
        """
        let backup = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(backup.pages, [])
        XCTAssertNil(backup.cards.first?.pageId)
    }

    /// A version 8 file, exactly as the previous build wrote it, reads the same
    /// through the version 9 decoder.
    func testAVersion8FileReadsUnchanged() throws {
        let json = """
        {
          "cards" : [
            {
              "back" : "Yanıt", "createdAt" : "1970-01-01T00:00:00Z",
              "difficulty" : 5, "dueDate" : "1970-01-01T00:00:00Z",
              "fesNegativeCount" : 1, "fesScore" : 2,
              "front" : "Soru", "id" : "00000000-0000-0000-0000-000000000001",
              "lapseCount" : 0, "lowConfidence" : false, "reviewCount" : 3,
              "reviews" : [], "softLapseCount" : 0, "stability" : 1,
              "status" : "active", "subject" : "Patoloji", "tags" : [],
              "topic" : "İnflamasyon", "type" : "direct_recall",
              "updatedAt" : "1970-01-01T00:00:00Z"
            }
          ],
          "exportedAt" : "1970-01-01T00:00:00Z",
          "formatVersion" : 8
        }
        """
        let backup = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(backup.formatVersion, 8)
        XCTAssertEqual(backup.pages, [])
        let card = try XCTUnwrap(backup.cards.first)
        XCTAssertNil(card.pageId)
        XCTAssertEqual(card.topic, "İnflamasyon")
        XCTAssertEqual(card.fesScore, 2)
        XCTAssertEqual(card.reviewCount, 3)
    }

    /// The example file from the task, as written — including its explicit
    /// `null`s, which a hand- or model-written file is likely to carry.
    func testTheExampleFileDecodesWithAUsablePhoto() throws {
        let json = """
        {
          "formatVersion": 9,
          "exportedAt": "2026-09-14T10:00:00Z",
          "pages": [
            { "id": "11111111-1111-1111-1111-111111111111",
              "jpegBase64": "\(Self.tinyJPEGBase64)",
              "captureDate": "2026-09-14T10:00:00Z",
              "subject": "Mikrobiyoloji",
              "readText": "★ Brucella: kültür en az 3 hafta bekletilmeli",
              "pageLabel": "FA Mikrobiyoloji s.126" }
          ],
          "cards": [
            { "id": "22222222-2222-2222-2222-222222222222",
              "pageId": "11111111-1111-1111-1111-111111111111",
              "type": "direct_recall",
              "front": "Brucella şüphesinde negatif sonuç için kültür en az ne kadar bekletilmelidir?",
              "back": "En az 3 hafta.",
              "explanation": null, "sourceQuote": null,
              "subject": "Mikrobiyoloji", "topic": "Bakteriyoloji",
              "status": "active",
              "dueDate": "2026-09-14T10:00:00Z", "stability": 0, "difficulty": 0,
              "reviewCount": 0, "lapseCount": 0,
              "createdAt": "2026-09-14T10:00:00Z", "updatedAt": "2026-09-14T10:00:00Z",
              "lastReviewedAt": null, "tags": [], "canonicalClaim": "★ Brucella: kültür en az 3 hafta bekletilmeli",
              "reviews": [], "options": null, "lowConfidence": false,
              "softLapseCount": 0, "lastPracticedAt": null,
              "fesScore": 0, "fesNegativeCount": 0, "fesInitializedAt": null }
          ]
        }
        """
        let backup = try BackupExporter.decode(Data(json.utf8))
        let page = try XCTUnwrap(backup.pages.first)
        XCTAssertTrue(page.hasUsableImage)
        XCTAssertEqual(page.pageLabel, "FA Mikrobiyoloji s.126")
        XCTAssertEqual(backup.cards.first?.pageId, page.id)
    }

    /// Content is forgiven, shape is not: an empty or garbled image loses that
    /// page's photo, never the whole file.
    func testAnUnusableImageStillLeavesTheFileReadable() throws {
        let json = """
        {"formatVersion":9,"exportedAt":"1970-01-01T00:00:00Z","cards":[],"pages":[
          {"id":"00000000-0000-0000-0000-0000000000A1","jpegBase64":"","captureDate":"1970-01-01T00:00:00Z"},
          {"id":"00000000-0000-0000-0000-0000000000A2","jpegBase64":"!!bu base64 değil!!","captureDate":"1970-01-01T00:00:00Z"},
          {"id":"00000000-0000-0000-0000-0000000000A3","jpegBase64":"aGVsbG8=","captureDate":"1970-01-01T00:00:00Z"}
        ]}
        """
        let backup = try BackupExporter.decode(Data(json.utf8))
        XCTAssertEqual(backup.pages.count, 3)
        // The third decodes fine — to "hello", which is not a JPEG.
        XCTAssertEqual(backup.pages.map(\.hasUsableImage), [false, false, false])
    }
}
