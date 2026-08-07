import XCTest
@testable import CizgiCore

/// The import decision (docs/PLAN-galeriden-foto.md §2.1, §3).
///
/// These are the rules that stop a HEIC from travelling to the provider wearing
/// an `image/jpeg` label, so they are tested on bytes rather than on files.
final class ImageFormatTests: XCTestCase {
    private func data(_ bytes: [UInt8], padTo count: Int = 32) -> Data {
        var all = bytes
        while all.count < count { all.append(0x00) }
        return Data(all)
    }

    func testDetectsJPEG() {
        XCTAssertEqual(ImageFormat.detect(data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
    }

    func testDetectsPNG() {
        XCTAssertEqual(
            ImageFormat.detect(data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            .png
        )
    }

    /// The whole reason this type exists: an iPhone photo is usually HEIC.
    func testDetectsHEICByBrand() {
        // 4-byte box size, "ftyp", brand.
        let heic = data([0x00, 0x00, 0x00, 0x18] + Array("ftypheic".utf8))
        XCTAssertEqual(ImageFormat.detect(heic), .heic)

        let live = data([0x00, 0x00, 0x00, 0x18] + Array("ftypmif1".utf8))
        XCTAssertEqual(ImageFormat.detect(live), .heic)
    }

    /// An MP4 also starts with `ftyp`; only the brand separates them, and a
    /// video must never be mistaken for a page.
    func testDoesNotCallEveryISOContainerHEIC() {
        let mp4 = data([0x00, 0x00, 0x00, 0x18] + Array("ftypisom".utf8))
        XCTAssertEqual(ImageFormat.detect(mp4), .unknown)
    }

    func testDetectsWebPOnlyWithBothMarkers() {
        let webp = data(Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WEBP".utf8))
        XCTAssertEqual(ImageFormat.detect(webp), .webp)

        let wav = data(Array("RIFF".utf8) + [0x00, 0x00, 0x00, 0x00] + Array("WAVE".utf8))
        XCTAssertEqual(ImageFormat.detect(wav), .unknown)
    }

    func testTooShortToSniffIsUnknown() {
        XCTAssertEqual(ImageFormat.detect(Data([0xFF, 0xD8])), .unknown)
        XCTAssertEqual(ImageFormat.detect(Data()), .unknown)
    }

    /// The provider list is the point of the flag, so it is pinned.
    func testHEICIsNotProviderSupported() {
        XCTAssertFalse(ImageFormat.heic.isProviderSupported)
        XCTAssertFalse(ImageFormat.tiff.isProviderSupported)
        XCTAssertFalse(ImageFormat.unknown.isProviderSupported)
        XCTAssertTrue(ImageFormat.jpeg.isProviderSupported)
        XCTAssertTrue(ImageFormat.png.isProviderSupported)
    }
}

final class ImportDecisionTests: XCTestCase {
    private func decision(
        format: ImageFormat = .jpeg,
        bytes: Int = 1_000_000,
        width: Int = 2000,
        height: Int = 1500,
        orientation: Int = ImportedImage.uprightOrientation
    ) -> ImportDecision {
        ImportedImage.decision(
            format: format,
            byteCount: bytes,
            pixelWidth: width,
            pixelHeight: height,
            orientation: orientation
        )
    }

    /// A plain, upright, reasonably sized JPEG is passed through: re-encoding
    /// it would lose quality and buy nothing.
    func testUprightJPEGIsLeftAlone() {
        XCTAssertFalse(decision().needsNormalization)
        XCTAssertTrue(decision().reasons.isEmpty)
    }

    func testHEICIsAlwaysConverted() {
        let result = decision(format: .heic)
        XCTAssertTrue(result.needsNormalization)
        XCTAssertEqual(result.reasons, [.unsupportedFormat])
    }

    /// PNG is a format the provider accepts, but it is still normalised: one
    /// format downstream is worth more than one avoided re-encode (§3).
    func testPNGIsConvertedToo() {
        XCTAssertEqual(decision(format: .png).reasons, [.unsupportedFormat])
    }

    /// A sideways photo is the failure nobody notices: the model reads the page
    /// rotated and never says so.
    func testRotatedJPEGIsRebaked() {
        XCTAssertEqual(decision(orientation: 6).reasons, [.orientation])
    }

    func testOversizeIsResized() {
        XCTAssertEqual(
            decision(width: ImportedImage.maxPixelSize + 1, height: 1000).reasons,
            [.tooManyPixels]
        )
        // The long edge is what counts, whichever way round the photo is.
        XCTAssertEqual(
            decision(width: 1000, height: ImportedImage.maxPixelSize + 1).reasons,
            [.tooManyPixels]
        )
        XCTAssertFalse(
            decision(width: ImportedImage.maxPixelSize, height: ImportedImage.maxPixelSize)
                .needsNormalization
        )
    }

    func testHeavyFileIsReencoded() {
        XCTAssertEqual(decision(bytes: ImportedImage.maxBytes + 1).reasons, [.tooManyBytes])
    }

    /// Several causes at once are all reported — the reason list is what a
    /// future "why was this photo re-encoded?" question reads.
    func testReasonsAccumulate() {
        let result = decision(
            format: .heic,
            bytes: ImportedImage.maxBytes + 1,
            width: ImportedImage.maxPixelSize + 500,
            height: 4000,
            orientation: 3
        )
        XCTAssertEqual(result.reasons, [.unsupportedFormat, .orientation, .tooManyPixels, .tooManyBytes])
    }
}
