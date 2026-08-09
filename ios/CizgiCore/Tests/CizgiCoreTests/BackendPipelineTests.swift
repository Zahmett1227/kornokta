import XCTest
@testable import CizgiCore

// The OCR-flow pipeline tests that used to live here — cloud reading, token
// grounding, OCR reconciliation, the photo confirmation gate — went with their
// subjects in the ADR-005 trim (2026-08-09). What remains is the one helper
// the vision flow still uses.

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
