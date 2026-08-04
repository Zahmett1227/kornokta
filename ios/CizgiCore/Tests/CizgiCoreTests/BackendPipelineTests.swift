import XCTest
import CoreGraphics
@testable import CizgiCore

// Faz 6 (docs/FAZ6-PLAN.md §8): the OCR-flow pipeline tests that used to live
// here — cloud reading, token grounding, OCR reconciliation, the photo
// confirmation gate — were archived when the vision pipeline replaced that
// machinery in the main flow. Their subjects (`documentAI`/`reconcile`/marker
// detection/grounding) still exist on disk for ADR-005's rollback and keep
// their own unit tests; what remains here are the small, still-live checks on
// helpers and wire types the vision flow (and the rollback path) both use.

final class LineOverlapTests: XCTestCase {
    func testBoxesOnTheSameLineOverlap() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertTrue(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.105, width: 0.8, height: 0.04))
    }

    func testBoxesOnDifferentLinesDoNot() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.50, width: 0.8, height: 0.04))
    }

    func testTouchingEdgesAreNotAnOverlap() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.14, width: 0.8, height: 0.04))
    }

    func testZeroSizedBoxNeverOverlaps() {
        let box = CGRect(x: 0.1, y: 0.10, width: 0.8, height: 0.04)
        XCTAssertFalse(CapturePipeline.overlaps(box: box, x: 0.1, y: 0.10, width: 0, height: 0))
    }
}

final class MimeTypeTests: XCTestCase {
    func testMapsTheExtensionsTheBackendAccepts() {
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.jpg")), "image/jpeg")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.PNG")), "image/png")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.tiff")), "image/tiff")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.pdf")), "application/pdf")
    }

    func testUnknownExtensionsDefaultToJpeg() {
        // The store writes .jpg, so this is the safe default; an unknown type
        // would otherwise be rejected by the backend with a 415.
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b")), "image/jpeg")
        XCTAssertEqual(CapturePipeline.mimeType(for: URL(fileURLWithPath: "/a/b.heic")), "image/jpeg")
    }
}

/// `styleInfoRequested` is new on `RemoteRecognition`. A device-local
/// `OCRSnapshot` saved before this field existed has no such key in its
/// persisted JSON at all — this must decode to `false`, not fail or crash.
/// (Retained type: `OCRSnapshot`/`RemoteRecognition` still exist for rollback.)
final class RemoteRecognitionStyleInfoDecodingTests: XCTestCase {
    private func minimalPageJSON() -> String {
        """
        {"imageWidth":100,"imageHeight":100,"elapsedMs":1,"lines":[],"tokens":[],"paragraphs":[],"blocks":[],"tables":[]}
        """
    }

    func testMissingStyleInfoRequestedKeyDecodesToFalse() throws {
        let json = """
        {"jobId":"job","page":\(minimalPageJSON())}
        """
        let decoded = try JSONDecoder().decode(RemoteRecognition.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.styleInfoRequested, "Eski (alan eklenmeden önce kaydedilmiş) bir OCRSnapshot false'a düşmeli, hataya değil")
    }

    func testPresentStyleInfoRequestedKeyRoundTrips() throws {
        let json = """
        {"jobId":"job","page":\(minimalPageJSON()),"styleInfoRequested":true}
        """
        let decoded = try JSONDecoder().decode(RemoteRecognition.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.styleInfoRequested)
    }
}
