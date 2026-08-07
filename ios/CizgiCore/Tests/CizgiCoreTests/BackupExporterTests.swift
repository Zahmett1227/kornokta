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
}
