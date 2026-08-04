import XCTest
import CoreGraphics
@testable import CizgiCore

/// Regression tests for `DetectedMarkerSelector` running token-level and
/// line-level analysis together instead of picking one for the whole page.
final class DetectedMarkerSelectorTests: XCTestCase {
    /// Draws a page white, then a dark rectangle mimicking a real underline —
    /// same geometry `TokenMarkerDetectionTests.testShortUnderlineIsDetectedAtTokenLevelEvenWhenItWouldBeTinyOnTheLine`
    /// already proved crosses the calibrated underline thresholds.
    private func imageWithUnderline(width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw XCTSkip("CGContext oluşturulamadı") }
        context.setFillColor(CGColor.sRGB(1, 1, 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor.sRGBGray(0.1, alpha: 1))
        // Core Graphics is bottom-left; the detector is top-left.
        context.fill(CGRect(x: 90, y: height - 58, width: 28, height: 2))
        guard let image = context.makeImage() else { throw XCTSkip("Görüntü üretilemedi") }
        return image
    }

    /// Regression test 1: the page has Apple tokens (on another line), but
    /// the physically marked line has none at all — Apple's own tokenizer
    /// produced nothing for it. The old `if tokenBoxes.isEmpty` branch (page-
    /// wide) meant that as long as *some* line elsewhere had tokens, this
    /// line got no candidate whatsoever. Line-level analysis must still catch
    /// it and keep it as a quick_confirm candidate, never silently dropped
    /// and never silently auto-accepted (a whole-line measurement is coarser
    /// than a token one).
    func testLineWithNoTokensStillProducesAQuickConfirmCandidateWhenOtherLinesHaveTokens() async throws {
        let width = 240, height = 100
        let image = try imageWithUnderline(width: width, height: height)
        let config = try MarkerConfig.bundled()
        let detector = MarkerDetector(config: config)

        let knownLine = RecognizedLine(
            id: "known", text: "Diğer", confidence: 0.9,
            box: CGRect(x: 0.02, y: 0.02, width: 0.20, height: 0.10),
            tokens: [RecognizedToken(id: "known_token_0", text: "Diğer", confidence: 0.9, box: CGRect(x: 0.02, y: 0.02, width: 0.20, height: 0.10))]
        )
        // No tokens at all for this line — the exact scenario the old
        // page-wide branch could not recover from.
        let markedLine = RecognizedLine(
            id: "marked", text: "", confidence: 0.5,
            box: CGRect(x: Double(90) / Double(width), y: Double(40) / Double(height), width: Double(28) / Double(width), height: Double(16) / Double(height)),
            tokens: []
        )
        let page = RecognizedPage(lines: [knownLine, markedLine], elapsed: 0)

        let selector = DetectedMarkerSelector(detector: detector, loadImage: { _ in image })
        let result = try await selector.select(in: page, imageURL: URL(fileURLWithPath: "/dev/null"))

        let markedGroup = result.groups.first { $0.selectedLineIds == ["marked"] }
        XCTAssertNotNil(markedGroup, "Tokensız satır için hâlâ bir aday üretilmeli")
        XCTAssertEqual(markedGroup?.selectionType, .underline)
        XCTAssertFalse(result.autoSelectedGroupIds.contains(markedGroup?.id ?? ""), "Satır seviyesi fallback tek başına otomatik kabul edilmemeli")
        let evidenceItem = result.evidence.first { markedGroup?.evidenceIds.contains($0.id) ?? false }
        XCTAssertEqual(evidenceItem?.provenance, .localLineFallback)
    }

    /// Realistic dedup bug: the marked line is *not* token-empty — Apple did
    /// tokenize a word on it, just not the marked one, and that ordinary
    /// token's box (as any real token on a line does) sits inside the line's
    /// own bounding box. The old dedup compared a line candidate against
    /// *every* token candidate regardless of that token's own verdict, and a
    /// line box always geometrically contains its own ordinary tokens — so
    /// this unmarked token alone was enough to silently delete a real
    /// line-level underline finding before evidence construction ever saw
    /// it. `markedTokenCandidates` (only `selectionType != .none`) fixes
    /// this: an unmarked token can no longer suppress a real line fallback.
    func testLineFallbackSurvivesAnUnmarkedAppleTokenOnTheSameMarkedLine() async throws {
        let width = 240, height = 100
        let image = try imageWithUnderline(width: width, height: height)
        let config = try MarkerConfig.bundled()
        let detector = MarkerDetector(config: config)

        let knownLine = RecognizedLine(
            id: "known", text: "Diğer", confidence: 0.9,
            box: CGRect(x: 0.02, y: 0.02, width: 0.20, height: 0.10),
            tokens: [RecognizedToken(id: "known_token_0", text: "Diğer", confidence: 0.9, box: CGRect(x: 0.02, y: 0.02, width: 0.20, height: 0.10))]
        )
        let markedLineBox = CGRect(x: Double(90) / Double(width), y: Double(40) / Double(height), width: Double(28) / Double(width), height: Double(16) / Double(height))
        // Fully inside `markedLineBox`, but nowhere near the drawn underline
        // strip (which sits right at/below the box's bottom edge) — plain
        // white background underneath, so token-level analysis must read
        // this one as `.none`.
        let ordinaryToken = RecognizedToken(
            id: "marked_token_0", text: "sözcük", confidence: 0.9,
            box: CGRect(x: 0.39, y: 0.41, width: 0.05, height: 0.10)
        )
        let markedLine = RecognizedLine(id: "marked", text: "sözcük", confidence: 0.5, box: markedLineBox, tokens: [ordinaryToken])
        let page = RecognizedPage(lines: [knownLine, markedLine], elapsed: 0)

        let selector = DetectedMarkerSelector(detector: detector, loadImage: { _ in image })
        let result = try await selector.select(in: page, imageURL: URL(fileURLWithPath: "/dev/null"))

        let ordinaryTokenDetection = detector.analyze(
            page: try PixelBuffer(cgImage: image),
            tokens: [TokenBox(ordinaryToken, lineId: "marked", imageWidth: width, imageHeight: height)],
            documentQuality: 0.5
        ).first
        XCTAssertEqual(ordinaryTokenDetection?.detection.selectionType, SelectionKind.none, "Test kurgusu geçersiz: sıradan token işaretli okunuyor")

        let markedGroup = result.groups.first { $0.selectedLineIds == ["marked"] }
        XCTAssertNotNil(markedGroup, "Sıradan (işaretsiz) bir Apple token'ı satırdaki gerçek fiziksel işareti silmemeli")
        XCTAssertEqual(markedGroup?.selectionType, .underline)
        XCTAssertFalse(result.autoSelectedGroupIds.contains(markedGroup?.id ?? ""), "Satır fallback'i hâlâ otomatik kabul edilmemeli")
        let evidenceItem = result.evidence.first { markedGroup?.evidenceIds.contains($0.id) ?? false }
        XCTAssertEqual(evidenceItem?.provenance, .localLineFallback)
    }

    /// Regression test 10: a token-level candidate and the line-level
    /// candidate covering the exact same physical mark must not both survive
    /// — deduping is by geometry, so this holds even though `DetectedMarkerSelector`
    /// runs both passes on every page now. This also proves the dedup fix
    /// above did not regress the genuine-match case: a really-marked token
    /// candidate (`selectionType != .none`) must still suppress the
    /// redundant line candidate over the same physical mark.
    func testTokenAndLineCandidatesForTheSameMarkAreNotProducedTwice() async throws {
        let width = 240, height = 100
        let image = try imageWithUnderline(width: width, height: height)
        let config = try MarkerConfig.bundled()
        let detector = MarkerDetector(config: config)

        let box = CGRect(x: Double(90) / Double(width), y: Double(40) / Double(height), width: Double(28) / Double(width), height: Double(16) / Double(height))
        let line = RecognizedLine(
            id: "L", text: "hipoksi", confidence: 0.9, box: box,
            tokens: [RecognizedToken(id: "L_token_0", text: "hipoksi", confidence: 0.95, box: box)]
        )
        let page = RecognizedPage(lines: [line], elapsed: 0)

        let selector = DetectedMarkerSelector(detector: detector, loadImage: { _ in image })
        let result = try await selector.select(in: page, imageURL: URL(fileURLWithPath: "/dev/null"))

        XCTAssertEqual(result.evidence.count, 1, "Aynı fiziksel işaret için hem token hem satır kanıtı üretilmemeli")
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.evidence.first?.provenance, .localToken, "Daha hassas token adayı önceliklidir")
    }
}
