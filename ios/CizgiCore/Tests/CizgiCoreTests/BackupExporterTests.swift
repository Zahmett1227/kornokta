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
}
