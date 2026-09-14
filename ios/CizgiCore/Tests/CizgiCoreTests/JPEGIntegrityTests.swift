import XCTest
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
#endif
@testable import CizgiCore

/// Real JPEG bytes for the backup tests. A stand-in like `FF D8 FF E0 …` is no
/// longer a "usable image" (Codex, PR #50), so the tests need the real thing.
enum TestJPEG {
    /// The 1×1 JPEG from the version 9 example file: small enough to inline,
    /// and a complete image ImageIO opens.
    static let tinyBase64 = "/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/yQALCAABAAEBAREA/8wABgAQEAX/2gAIAQEAAD8A0s8g/9k="
    static let tiny = Data(base64Encoded: tinyBase64)!

    /// A page-sized JPEG with structure in it, so there is scan data worth
    /// cutting.
    static func rendered(width: Int = 300, height: Int = 400, progressive: Bool = false) throws -> Data {
        #if canImport(ImageIO)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw XCTSkip("CGContext oluşturulamadı") }
        context.setFillColor(CGColor.sRGBGray(1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor.sRGBGray(0.1, alpha: 1))
        for row in stride(from: 0, to: height, by: 9) {
            context.fill(CGRect(x: row % 40, y: row, width: width / 2, height: 4))
        }
        guard let image = context.makeImage() else { throw XCTSkip("görüntü yok") }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("JPEG hedefi yok")
        }
        var options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        if progressive {
            options[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("JPEG yazılamadı") }
        return output as Data
        #else
        throw XCTSkip("ImageIO yok")
        #endif
    }
}

final class JPEGIntegrityTests: XCTestCase {

    func testWholeImagesAreComplete() throws {
        XCTAssertTrue(JPEGIntegrity.isComplete(TestJPEG.tiny))
        XCTAssertTrue(JPEGIntegrity.isComplete(try TestJPEG.rendered()))
        XCTAssertTrue(JPEGIntegrity.isComplete(try TestJPEG.rendered(progressive: true)))
    }

    /// The case the start-of-image check let through: a field cut off
    /// part-way keeps its first bytes. ImageIO alone still "opens" these.
    func testATruncatedImageIsNotComplete() throws {
        for data in [try TestJPEG.rendered(), try TestJPEG.rendered(progressive: true)] {
            for keep in [data.count / 2, data.count - 2, 300, 4] {
                XCTAssertFalse(
                    JPEGIntegrity.isComplete(data.prefix(keep)),
                    "\(data.count) baytın \(keep)'i tam sayılmamalı"
                )
            }
        }
    }

    /// A slice's indices do not start at zero; the walk must not care.
    func testASliceOfACompleteImageIsStillComplete() throws {
        let data = try TestJPEG.rendered()
        let padded = Data([0x00, 0x00]) + data
        XCTAssertTrue(JPEGIntegrity.isComplete(padded.dropFirst(2)))
    }

    /// Bytes after end-of-image (a trailer some phones append) do not make a
    /// whole image incomplete.
    func testTrailingBytesAfterTheEndOfImageAreIgnored() throws {
        let data = try TestJPEG.rendered() + Data("trailer".utf8)
        XCTAssertTrue(JPEGIntegrity.isComplete(data))
    }

    func testNonImagesAreNotComplete() {
        XCTAssertFalse(JPEGIntegrity.isComplete(Data()))
        XCTAssertFalse(JPEGIntegrity.isComplete(Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])))
        XCTAssertFalse(JPEGIntegrity.isComplete(Data("hello".utf8)))
        // Right markers, nothing a decoder can read: SOI, an empty APP0, EOI.
        XCTAssertFalse(JPEGIntegrity.isComplete(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x02, 0xFF, 0xD9])))
    }

    #if canImport(ImageIO)
    /// A PNG decodes, but it is not what the stored `-original.jpg` and the
    /// `image/jpeg` uploads promise.
    func testAPNGIsNotAJPEG() throws {
        let jpeg = try TestJPEG.rendered()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertFalse(JPEGIntegrity.isComplete(output as Data))
    }
    #endif

    /// Through the backup type itself: the flag restore planning reads.
    func testAPageRecordWithACutImageIsNotUsable() throws {
        let data = try TestJPEG.rendered()
        func page(_ bytes: Data) -> BackupExporter.PageRecord {
            BackupExporter.PageRecord(id: UUID(), jpegData: bytes, captureDate: Date(timeIntervalSince1970: 0))
        }
        XCTAssertTrue(page(data).hasUsableImage)
        XCTAssertFalse(page(data.prefix(data.count / 2)).hasUsableImage)
    }
}
