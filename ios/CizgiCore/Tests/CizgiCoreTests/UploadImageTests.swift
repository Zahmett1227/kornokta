import XCTest
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
#endif
@testable import CizgiCore

/// Builds a real JPEG of the given size, so the encoder is exercised against
/// actual image bytes rather than a stand-in.
private func jpegData(width: Int, height: Int, quality: Double = 0.9) throws -> Data {
    #if canImport(ImageIO)
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { throw XCTSkip("CGContext oluşturulamadı") }

    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    // Some structure, so the encoder has something to compress and the result
    // is not a degenerate few-byte file.
    context.setFillColor(CGColor(gray: 0.15, alpha: 1))
    for row in stride(from: 0, to: height, by: 8) {
        context.fill(CGRect(x: 0, y: row, width: width, height: 3))
    }

    guard
        let image = context.makeImage(),
        let data = UploadImageEncoder.jpeg(from: image, quality: quality)
    else { throw XCTSkip("JPEG üretilemedi") }
    return data
    #else
    throw XCTSkip("ImageIO yok")
    #endif
}

private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
    #if canImport(ImageIO)
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return UploadImageEncoder.pixelSize(of: source)
    #else
    return nil
    #endif
}

final class UploadImageEncoderTests: XCTestCase {
    func testASmallPageIsSentExactlyAsItWasStored() throws {
        // Re-encoding a JPEG loses a little every time. When the original
        // already fits there is nothing to gain by touching it.
        let original = try jpegData(width: 400, height: 300)
        let prepared = UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")

        XCTAssertFalse(prepared.wasResized)
        XCTAssertEqual(prepared.data, original)
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
    }

    func testAFullResolutionScanIsBroughtUnderTheLongEdgeLimit() throws {
        // The case that matters: an untouched capture base64s past what a
        // serverless host accepts, and is rejected before our endpoint can say
        // why. Long and thin so the test stays cheap while still crossing the
        // 2600 px limit on its long edge.
        let original = try jpegData(width: 3000, height: 120)
        let prepared = UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")

        XCTAssertTrue(prepared.wasResized)
        let size = try XCTUnwrap(pixelSize(of: prepared.data))
        XCTAssertLessThanOrEqual(
            max(size.width, size.height),
            UploadImageEncoder.defaultMaxPixelSize
        )
    }

    func testResizingKeepsTheShapeOfThePage() throws {
        let original = try jpegData(width: 3000, height: 1500)
        let prepared = UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")
        let size = try XCTUnwrap(pixelSize(of: prepared.data))

        // A page squashed on one axis would read as smeared text.
        XCTAssertEqual(Double(size.width) / Double(size.height), 2.0, accuracy: 0.02)
    }

    func testTheResultStaysWithinTheUploadBudget() throws {
        let original = try jpegData(width: 3000, height: 2000, quality: 1.0)
        let prepared = UploadImageEncoder.prepare(original: original, mimeType: "image/jpeg")

        XCTAssertLessThanOrEqual(prepared.data.count, UploadImageEncoder.defaultMaxBytes)
        // And still under the host limit once base64 has added its third.
        let base64Size = Int(Double(prepared.data.count) * 4.0 / 3.0)
        XCTAssertLessThan(base64Size, 4_500_000)
    }

    func testAnImageThatIsShortButHeavyIsStillReduced() throws {
        // Under the pixel limit yet over the byte budget. Driven with explicit
        // limits so the test does not need a genuinely huge file to make the
        // point.
        let original = try jpegData(width: 1200, height: 1200, quality: 1.0)
        let prepared = UploadImageEncoder.prepare(
            original: original,
            mimeType: "image/jpeg",
            maxPixelSize: 2600,
            maxBytes: original.count / 2
        )
        XCTAssertTrue(prepared.wasResized)
        XCTAssertLessThan(prepared.data.count, original.count)
    }

    func testAPDFIsPassedThroughRatherThanRasterized() {
        // Rasterizing would throw away the text layer the OCR would rather have.
        let bytes = Data("%PDF-1.4 sahte".utf8)
        let prepared = UploadImageEncoder.prepare(original: bytes, mimeType: "application/pdf")

        XCTAssertFalse(prepared.wasResized)
        XCTAssertEqual(prepared.data, bytes)
        XCTAssertEqual(prepared.mimeType, "application/pdf")
    }

    func testUndecodableBytesAreSentRatherThanLost() {
        // §21.2: a capture must not disappear because a decoder was unhappy.
        // The server's own limit answers with something the user can act on.
        let bytes = Data(repeating: 0x41, count: 512)
        let prepared = UploadImageEncoder.prepare(original: bytes, mimeType: "image/jpeg")

        XCTAssertFalse(prepared.wasResized)
        XCTAssertEqual(prepared.data, bytes)
    }

    func testResizedUploadsAreAlwaysDeclaredAsJPEG() throws {
        // Whatever went in, a re-encoded page comes out as JPEG — the mime type
        // has to follow, or the backend rejects it with a 415.
        let original = try jpegData(width: 3000, height: 120)
        let prepared = UploadImageEncoder.prepare(original: original, mimeType: "image/heic")

        XCTAssertTrue(prepared.wasResized)
        XCTAssertEqual(prepared.mimeType, "image/jpeg")
    }

    func testReadsFromDisk() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try jpegData(width: 3000, height: 120).write(to: url)

        let prepared = try UploadImageEncoder.prepare(contentsOf: url, mimeType: "image/jpeg")
        XCTAssertTrue(prepared.wasResized)
    }

    func testAMissingFileThrowsRatherThanReturningEmptyBytes() {
        let url = URL(fileURLWithPath: "/yok/olmayan/dosya.jpg")
        XCTAssertThrowsError(
            try UploadImageEncoder.prepare(contentsOf: url, mimeType: "image/jpeg")
        )
    }
}
