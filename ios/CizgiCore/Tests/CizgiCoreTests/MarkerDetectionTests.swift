import XCTest
import CoreGraphics
@testable import CizgiCore

/// Locates a repo file from the test source path, so the tests read the same
/// shared files the Python side writes.
private func repoFile(_ relativePath: String) -> URL {
    URL(fileURLWithPath: #filePath)          // .../ios/CizgiCore/Tests/CizgiCoreTests/x.swift
        .deletingLastPathComponent()          // CizgiCoreTests
        .deletingLastPathComponent()          // Tests
        .deletingLastPathComponent()          // CizgiCore
        .deletingLastPathComponent()          // ios
        .deletingLastPathComponent()          // repo root
        .appendingPathComponent(relativePath)
}

private struct MarkerCase: Decodable {
    struct Input: Decodable {
        struct Underline: Decodable {
            let darkRatio: Double
            let extentRatio: Double
            let thicknessRatio: Double
            let overrunRatio: Double
            let overrunObserved: Bool
        }
        let highlightOverlap: Double
        let underline: Underline
        let ocrConfidence: Double
        let documentQuality: Double
        let neighboringSeparation: Double
    }
    struct Expected: Decodable {
        let markerOverlap: Double
        let lineGeometry: Double
        let selectionConfidence: Double
        let selectionType: String
        let decision: String
    }
    let name: String
    let input: Input
    let expected: Expected
}

private struct MarkerCaseFile: Decodable {
    let cases: [MarkerCase]
}

final class MarkerDecisionSharedCaseTests: XCTestCase {
    private var detector: MarkerDetector!
    private var cases: [MarkerCase]!

    override func setUpWithError() throws {
        let config = try MarkerConfig.load(
            contentsOf: repoFile("evals/spikes/marker_detection/config.json")
        )
        detector = MarkerDetector(config: config)
        let data = try Data(contentsOf: repoFile("evals/shared/marker-decision-cases.json"))
        cases = try JSONDecoder().decode(MarkerCaseFile.self, from: data).cases
    }

    func testTheCaseListIsNotVacuous() {
        // Guards the guard: an empty list would make every assertion below
        // pass without checking anything.
        XCTAssertGreaterThan(cases.count, 15)
        XCTAssertTrue(cases.contains { $0.expected.decision == "auto_candidate" })
        XCTAssertTrue(cases.contains { $0.expected.decision == "quick_confirm" })
        XCTAssertTrue(cases.contains { $0.expected.decision == "user_selection" })
    }

    /// The contract with the Python reference. A divergence here means the
    /// phone would decide differently from the measurement that calibrated it.
    func testEveryCaseMatchesTheReference() {
        for entry in cases {
            let measurement = LineMeasurement(
                lineId: entry.name,
                highlightOverlap: entry.input.highlightOverlap,
                underline: UnderlineEvidence(
                    darkRatio: entry.input.underline.darkRatio,
                    extentRatio: entry.input.underline.extentRatio,
                    thicknessRatio: entry.input.underline.thicknessRatio,
                    overrunRatio: entry.input.underline.overrunRatio,
                    overrunObserved: entry.input.underline.overrunObserved
                ),
                ocrConfidence: entry.input.ocrConfidence,
                documentQuality: entry.input.documentQuality,
                neighboringSeparation: entry.input.neighboringSeparation
            )
            let actual = detector.judge(measurement)

            XCTAssertEqual(actual.selectionType.rawValue, entry.expected.selectionType, entry.name)
            XCTAssertEqual(actual.decision.rawValue, entry.expected.decision, entry.name)
            XCTAssertEqual(actual.selectionConfidence, entry.expected.selectionConfidence, accuracy: 0.0001, entry.name)
            XCTAssertEqual(actual.markerOverlap, entry.expected.markerOverlap, accuracy: 0.0001, entry.name)
            XCTAssertEqual(actual.lineGeometry, entry.expected.lineGeometry, accuracy: 0.0001, entry.name)
        }
    }
}

final class MarkerConfigTests: XCTestCase {
    func testTheBundledCopyMatchesTheReference() throws {
        // The Python suite checks the files are byte-identical; this checks the
        // bundled one actually loads and carries the same numbers, which a
        // resource-declaration mistake would break without changing bytes.
        let reference = try MarkerConfig.load(
            contentsOf: repoFile("evals/spikes/marker_detection/config.json")
        )
        let bundled = try MarkerConfig.bundled()
        XCTAssertEqual(bundled, reference)
    }

    func testWeightsSumToOne() throws {
        // Otherwise `selectionConfidence` is not comparable with the
        // thresholds sitting beside it (§9.3).
        let weights = try MarkerConfig.bundled().confidenceWeights
        let total = weights.markerOverlap + weights.lineGeometry + weights.localOCRConfidence
            + weights.documentQuality + weights.neighboringLineSeparation
        XCTAssertEqual(total, 1.0, accuracy: 1e-9)
    }

    func testHueRangesAreFlattened() throws {
        let config = try MarkerConfig.bundled()
        // Pink wraps past the end of the 0–179 scale, so it contributes two
        // ranges; a flattening that dropped one would stop detecting it.
        XCTAssertGreaterThanOrEqual(config.hueRanges.count, 5)
    }
}

// MARK: - Pixel-level behaviour

/// Draws a synthetic page: white background, grey text bars, and whatever
/// marks a test asks for. Synthetic on purpose — real book pages are
/// copyrighted and must not be committed (§26, §30).
private func syntheticPage(
    width: Int = 200,
    height: Int = 120,
    draw: (CGContext) -> Void
) throws -> PixelBuffer {
    // Named sRGB, not `CGColorSpaceCreateDeviceRGB()`, for the same
    // reproducibility reason `PixelBuffer.pixelColorSpace` is. The actual
    // colour-drift bug this suite caught was elsewhere — see `CGColor.sRGB`
    // — but there is no reason for the context itself to stay ambiguous too.
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw XCTSkip("CGContext oluşturulamadı")
    }
    context.setFillColor(CGColor.sRGB(1, 1, 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    draw(context)
    guard let image = context.makeImage() else { throw XCTSkip("CGImage üretilemedi") }
    return try PixelBuffer(cgImage: image)
}

/// Core Graphics has a bottom-left origin; the detector works top-left. This
/// converts so tests can be written in the detector's frame.
private func flipped(_ rect: CGRect, in height: Int) -> CGRect {
    CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
}

final class PixelBufferTests: XCTestCase {
    func testReadsBackTheColourItWasGiven() throws {
        let buffer = try syntheticPage(width: 10, height: 10) { context in
            context.setFillColor(CGColor.sRGB(1, 0, 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        let (r, g, b) = buffer.rgb(x: 5, y: 5)
        XCTAssertEqual(r, 255, accuracy: 2)
        XCTAssertEqual(g, 0, accuracy: 2)
        XCTAssertEqual(b, 0, accuracy: 2)
    }

    func testHueUsesTheOpenCVScale() throws {
        // The shared thresholds are written for 0–179; on a 0–360 scale every
        // hue range would silently point at the wrong colour.
        let yellow = try syntheticPage(width: 4, height: 4) { context in
            context.setFillColor(CGColor.sRGB(1, 1, 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        let (h, s, v) = yellow.hsv(x: 2, y: 2)
        XCTAssertEqual(h, 30, accuracy: 2)   // 60° / 2
        XCTAssertEqual(s, 255, accuracy: 3)
        XCTAssertEqual(v, 255, accuracy: 3)
    }

    func testOutOfBoundsReadsAreBlackRatherThanACrash() {
        let buffer = PixelBuffer(width: 2, height: 2, pixels: [UInt8](repeating: 255, count: 16))
        let (r, _, _) = buffer.rgb(x: 99, y: 99)
        XCTAssertEqual(r, 0)
        XCTAssertEqual(buffer.gray(x: -1, y: -1), 0)
    }
}

final class PixelRegionTests: XCTestCase {
    private let buffer = PixelBuffer(width: 100, height: 50, pixels: [UInt8](repeating: 255, count: 100 * 50 * 4))

    func testClampsToTheImage() {
        let region = PixelRegion(x: -10, y: -10, width: 30, height: 30, in: buffer)
        XCTAssertEqual(region?.x, 0)
        XCTAssertEqual(region?.y, 0)
        XCTAssertEqual(region?.width, 20)
    }

    func testRegionWhollyOutsideIsNilNotAWrappedSlice() {
        // The bug the reference implementation hit: a negative upper bound read
        // as an offset from the far edge, selecting a large unrelated region.
        XCTAssertNil(PixelRegion(x: -100, y: 0, width: 50, height: 10, in: buffer))
        XCTAssertNil(PixelRegion(x: 200, y: 0, width: 50, height: 10, in: buffer))
        XCTAssertNil(PixelRegion(x: 0, y: -100, width: 10, height: 50, in: buffer))
    }

    func testZeroSizedRegionIsNil() {
        XCTAssertNil(PixelRegion(x: 0, y: 0, width: 0, height: 10, in: buffer))
    }
}

final class MarkerDetectorPixelTests: XCTestCase {
    private var detector: MarkerDetector!

    override func setUpWithError() throws {
        detector = MarkerDetector(config: try MarkerConfig.bundled())
    }

    private let line = LineBox(lineId: "line_00", x: 20, y: 40, width: 120, height: 16)

    func testFindsAYellowHighlightOverTheLine() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGB(1, 0.95, 0.1, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 40, width: 120, height: 16), in: 120))
        }
        XCTAssertGreaterThan(detector.highlightOverlap(in: page, line: line), 0.9)
    }

    func testPlainTextIsNotAHighlight() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGBGray(0.2, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 44, width: 120, height: 8), in: 120))
        }
        XCTAssertLessThan(detector.highlightOverlap(in: page, line: line), 0.05)
    }

    func testFindsAnUnderlineJustBelowTheBaseline() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGBGray(0.15, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 56, width: 120, height: 2), in: 120))
        }
        let evidence = detector.underlineEvidence(in: page, line: line)
        XCTAssertGreaterThan(evidence.extentRatio, 0.8)
        XCTAssertGreaterThan(evidence.darkRatio, 0.1)
    }

    func testABlankPageHasNoUnderline() throws {
        let page = try syntheticPage { _ in }
        let evidence = detector.underlineEvidence(in: page, line: line)
        XCTAssertEqual(evidence.extentRatio, 0, accuracy: 0.01)
    }

    func testALineAtTheImageEdgeReportsOverrunAsUnknown() throws {
        // §19.2/P3: unknown must be routed to the user, not read as "no
        // overrun". A line flush against the edge has no visible margin.
        let page = try syntheticPage(width: 140, height: 120) { context in
            context.setFillColor(CGColor.sRGBGray(0.15, alpha: 1))
            context.fill(flipped(CGRect(x: 0, y: 56, width: 140, height: 2), in: 120))
        }
        let edgeLine = LineBox(lineId: "edge", x: 0, y: 40, width: 140, height: 16)
        let evidence = detector.underlineEvidence(in: page, line: edgeLine)
        XCTAssertFalse(evidence.overrunObserved)

        // And the judgement must not auto-accept it however good it looks.
        let decision = detector.judge(
            LineMeasurement(
                lineId: "edge",
                highlightOverlap: 0,
                underline: evidence,
                ocrConfidence: 0.99,
                documentQuality: 0.99,
                neighboringSeparation: 1.0
            )
        )
        XCTAssertNotEqual(decision.decision, .autoCandidate)
    }

    func testARuleThatRunsPastTheTextIsSeenAsOverrunning() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGBGray(0.15, alpha: 1))
            // Spans the whole page, well beyond the text line.
            context.fill(flipped(CGRect(x: 0, y: 56, width: 200, height: 2), in: 120))
        }
        let evidence = detector.underlineEvidence(in: page, line: line)
        XCTAssertTrue(evidence.overrunObserved)
        XCTAssertGreaterThan(evidence.overrunRatio, 0.6)
    }

    func testAPenStrokeThatStopsAtTheTextDoesNotOverrun() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGBGray(0.15, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 56, width: 120, height: 2), in: 120))
        }
        let evidence = detector.underlineEvidence(in: page, line: line)
        XCTAssertTrue(evidence.overrunObserved)
        XCTAssertLessThan(evidence.overrunRatio, 0.3)
    }

    /// Printed, colour-only "ink" — no separate black text at all — must not
    /// read as a highlighter mark just because it passes the raw hue/
    /// saturation/value gate (found via real device use, 2026-08-04: a
    /// saturated printed heading such as "SJÖGREN SENDROMU" produced a false
    /// marker candidate).
    func testPrintedColoredHeadingIsNotReadAsAHighlight() throws {
        let page = try syntheticPage { context in
            // Within the configured "yellow" hue range, same as a real
            // saturated printed heading colour — but, unlike the highlighter
            // fixtures below, with no separate black ink anywhere at all.
            context.setFillColor(CGColor.sRGB(1, 0.75, 0, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 40, width: 60, height: 16), in: 120))
        }
        XCTAssertGreaterThanOrEqual(
            detector.highlightOverlap(in: page, line: line), 0.25,
            "Test kurgusu geçersiz: renk eşiğini geçmiyor"
        )
        XCTAssertFalse(
            detector.hasUnderlyingDarkText(in: page, line: line),
            "Basılı renkli mürekkebin altında ayrı bir siyah metin yok"
        )
        let detection = detector.analyze(page: page, lines: [line]).first
        XCTAssertNotEqual(detection?.selectionType, .highlight, "Basılı renkli başlık fosforlu kalem sayılmamalı")
    }

    /// The positive counterpart: a translucent highlighter drawn over real
    /// black print must still be detected — the new gate only rejects the
    /// *absence* of underlying text, not colour itself.
    func testRealHighlighterOverBlackTextStillReadsAsAHighlight() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGB(1, 0.95, 0.1, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 40, width: 120, height: 16), in: 120))
            context.setFillColor(CGColor.sRGBGray(0.05, alpha: 1))
            for stripeX in stride(from: 24, to: 136, by: 12) {
                context.fill(flipped(CGRect(x: CGFloat(stripeX), y: 44, width: 3, height: 8), in: 120))
            }
        }
        XCTAssertTrue(detector.hasUnderlyingDarkText(in: page, line: line))
        let detection = detector.analyze(page: page, lines: [line]).first
        XCTAssertEqual(detection?.selectionType, .highlight)
    }

    /// A line-level fallback has no token geometry to narrow its evidence box
    /// to — but the pixel measurement that judged it already knows where
    /// within the line the mark sits, and must not report the whole line
    /// (§3: markerBounds vs textBounds).
    func testHighlightPixelBoundsAreTighterThanTheWholeLine() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGB(1, 0.95, 0.1, alpha: 1))
            context.fill(flipped(CGRect(x: 20, y: 40, width: 30, height: 16), in: 120))
        }
        let bounds = try XCTUnwrap(detector.markerPixelBounds(in: page, line: line, selectionType: .highlight))
        XCTAssertEqual(bounds.width, 30, accuracy: 2)
        XCTAssertLessThan(bounds.width, Double(line.width))
    }

    func testUnderlinePixelBoundsAreTighterThanTheWholeLine() throws {
        let page = try syntheticPage { context in
            context.setFillColor(CGColor.sRGBGray(0.15, alpha: 1))
            context.fill(flipped(CGRect(x: 60, y: 56, width: 20, height: 2), in: 120))
        }
        let bounds = try XCTUnwrap(detector.markerPixelBounds(in: page, line: line, selectionType: .underline))
        XCTAssertEqual(bounds.minX, 60, accuracy: 2)
        XCTAssertLessThan(bounds.width, Double(line.width))
        XCTAssertEqual(bounds.height, Double(line.height))
    }

    /// `nil` (no matching pixel at all) must not crash a caller that force-
    /// unwraps — a blank region simply has no bounds to report.
    func testMarkerPixelBoundsIsNilWhenNothingMatches() throws {
        let page = try syntheticPage { _ in }
        XCTAssertNil(detector.markerPixelBounds(in: page, line: line, selectionType: .highlight))
        XCTAssertNil(detector.markerPixelBounds(in: page, line: line, selectionType: .underline))
    }
}

final class NeighborSeparationTests: XCTestCase {
    func testALoneLineIsFullySeparated() {
        let line = LineBox(lineId: "a", x: 0, y: 0, width: 100, height: 20)
        XCTAssertEqual(MarkerDetector.neighboringSeparation(line, among: [line]), 1.0)
    }

    func testAFarNeighbourIsFullySeparated() {
        let a = LineBox(lineId: "a", x: 0, y: 0, width: 100, height: 20)
        let b = LineBox(lineId: "b", x: 0, y: 60, width: 100, height: 20)
        XCTAssertEqual(MarkerDetector.neighboringSeparation(a, among: [a, b]), 1.0)
    }

    func testACloseNeighbourLowersIt() {
        let a = LineBox(lineId: "a", x: 0, y: 0, width: 100, height: 20)
        let b = LineBox(lineId: "b", x: 0, y: 24, width: 100, height: 20)
        let separation = MarkerDetector.neighboringSeparation(a, among: [a, b])
        XCTAssertEqual(separation, 0.2, accuracy: 0.01)
    }

    func testTouchingLinesScoreZero() {
        let a = LineBox(lineId: "a", x: 0, y: 0, width: 100, height: 20)
        let b = LineBox(lineId: "b", x: 0, y: 20, width: 100, height: 20)
        XCTAssertEqual(MarkerDetector.neighboringSeparation(a, among: [a, b]), 0)
    }
}

final class LongestRunTests: XCTestCase {
    func testCountsTheLongestConsecutiveRun() {
        XCTAssertEqual(MarkerDetector.longestRun([true, true, false, true]), 2)
        XCTAssertEqual(MarkerDetector.longestRun([false, false]), 0)
        XCTAssertEqual(MarkerDetector.longestRun([]), 0)
        XCTAssertEqual(MarkerDetector.longestRun([true, true, true]), 3)
    }
}

final class SelectedLineTests: XCTestCase {
    private func detection(_ id: String, _ decision: MarkerDecision) -> LineDetection {
        LineDetection(
            lineId: id,
            markerOverlap: 0,
            lineGeometry: 0,
            localOCRConfidence: 0,
            documentQuality: 0,
            neighboringSeparation: 0,
            selectionConfidence: 0,
            selectionType: .none,
            decision: decision
        )
    }

    func testOnlyAutoCandidatesAreSelectedByDefault() {
        // §19.3: a capture with no detected marker must not become a card, and
        // a pending line is one the detector is unsure about.
        let detections = [
            detection("a", .autoCandidate),
            detection("b", .quickConfirm),
            detection("c", .userSelection),
        ]
        XCTAssertEqual(MarkerDetector.selectedLineIds(detections), ["a"])
    }

    func testPendingLinesCanBeIncludedExplicitly() {
        let detections = [detection("a", .autoCandidate), detection("b", .quickConfirm)]
        XCTAssertEqual(MarkerDetector.selectedLineIds(detections, includePending: true), ["a", "b"])
    }
}
