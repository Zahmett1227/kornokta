import XCTest
import CoreGraphics
@testable import CizgiCore

private func annotationLine(_ id: String, _ text: String, x: Double, y: Double) -> RemoteLine {
    RemoteLine(
        lineId: id, text: text, confidence: 0.98,
        x: x, y: y, width: 0.36, height: 0.04,
        tokenIds: ["\(id)_token"]
    )
}

private func annotationToken(_ id: String, _ text: String, x: Double, y: Double) -> RemoteToken {
    RemoteToken(
        tokenId: id, text: text, confidence: 0.98,
        x: x, y: y, width: 0.09, height: 0.025
    )
}

private func markerEvidence(_ id: String, line: String, token: String, x: Double, y: Double) -> AnnotationEvidence {
    AnnotationEvidence(
        id: id,
        type: .underline,
        boundingBox: NormalizedRect(x: x, y: y, width: 0.10, height: 0.03),
        lineIds: [line], tokenIds: [token], confidence: 0.9, decision: .autoCandidate
    )
}

private func markerGroup(_ id: String, evidence: AnnotationEvidence) -> AnnotationGroup {
    AnnotationGroup(
        id: id, evidenceIds: [evidence.id], selectedLineIds: evidence.lineIds,
        contextLineIds: evidence.lineIds, selectedTokenIds: evidence.tokenIds,
        boundingBox: evidence.boundingBox, confidence: evidence.confidence,
        needsConfirmation: false, selectionType: evidence.type
    )
}

final class AnnotationGrouperTests: XCTestCase {
    func testDocumentAIBlockLayoutKindDecodes() throws {
        let data = try XCTUnwrap("\"block\"".data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode(AnnotationLayoutKind.self, from: data), .block)
    }

    func testOfflineManualRectangleUsesLocalLineGeometry() {
        let manual = AnnotationGroup(
            id: "manual", evidenceIds: [], selectedLineIds: [], contextLineIds: [],
            boundingBox: NormalizedRect(x: 0.15, y: 0.20, width: 0.35, height: 0.05),
            confidence: 1, needsConfirmation: false, selectionType: .manual
        )
        let local = RecognizedPage(lines: [RecognizedLine(
            id: "local", text: "Yerel seçilmiş pasaj", confidence: 0.9,
            box: CGRect(x: 0.10, y: 0.19, width: 0.50, height: 0.06)
        )], elapsed: 0)

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(groups: [manual], autoSelectedGroupIds: ["manual"]),
            localPage: local, remotePage: nil
        )

        XCTAssertEqual(grounded.groups.first?.selectedText, "Yerel seçilmiş pasaj")
        XCTAssertEqual(grounded.groups.first?.selectedLineIds, ["local"])
    }

    func testConfirmationDoesNotRediscoverRejectedHandwriting() {
        let evidence = markerEvidence("e", line: "local", token: "token", x: 0.2, y: 0.2)
        let base = markerGroup("group", evidence: evidence)
        let page = RemotePage(
            imageWidth: 100, imageHeight: 100, elapsedMs: 1,
            lines: [annotationLine("remote", "Seçili bilgi", x: 0.1, y: 0.19)],
            tokens: [
                annotationToken("text", "bilgi", x: 0.2, y: 0.2),
                RemoteToken(tokenId: "note", text: "not", confidence: 0.8, x: 0.8, y: 0.2, width: 0.08, height: 0.03, isHandwritten: true)
            ]
        )
        let initial = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [evidence], groups: [base], autoSelectedGroupIds: ["group"]),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        let confirmed = initial.groups.filter { $0.selectionType != .handwriting }.map { $0.markedConfirmed() }
        let resumed = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [evidence], groups: confirmed, autoSelectedGroupIds: ["group"]),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page, discoverHandwriting: false
        )

        XCTAssertFalse(resumed.groups.contains { $0.selectionType == .handwriting })
    }

    func testShortPhraseUnderlineUsesTokenGeometryAndExpandsOnlyToItsLine() {
        let evidence = markerEvidence("e", line: "vision_0", token: "vision_0_t", x: 0.44, y: 0.20)
        let group = markerGroup("g", evidence: evidence)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("google_0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [annotationToken("google_0_token", "hipoksi", x: 0.44, y: 0.20)]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [evidence], groups: [group], autoSelectedGroupIds: ["g"]),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 1)
        XCTAssertEqual(grounded.groups[0].selectedText, "hipoksi")
        XCTAssertEqual(grounded.groups[0].contextText, "Hücre hasarının en sık sebebi hipoksidir.")
    }

    func testSameTextInDifferentRegionsRemainsTwoGroups() {
        let first = markerEvidence("e1", line: "v1", token: "v1t", x: 0.15, y: 0.20)
        let second = markerEvidence("e2", line: "v2", token: "v2t", x: 0.15, y: 0.70)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                annotationLine("r1", "miyelin figürler", x: 0.10, y: 0.19),
                annotationLine("r2", "miyelin figürler", x: 0.10, y: 0.69),
            ],
            tokens: [
                annotationToken("r1_token", "miyelin", x: 0.15, y: 0.20),
                annotationToken("r2_token", "miyelin", x: 0.15, y: 0.70),
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [first, second], groups: [markerGroup("g1", evidence: first), markerGroup("g2", evidence: second)],
                autoSelectedGroupIds: ["g1", "g2"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 2)
        XCTAssertEqual(Set(grounded.groups.map(\.selectedText)), ["miyelin"])
        XCTAssertNotEqual(grounded.groups[0].boundingBox, grounded.groups[1].boundingBox)
    }

    func testTwoColumnsDoNotBecomeOneGroup() {
        let left = markerEvidence("left_e", line: "left", token: "left_t", x: 0.12, y: 0.30)
        let right = markerEvidence("right_e", line: "right", token: "right_t", x: 0.62, y: 0.30)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                annotationLine("left_r", "Nekroz: membran hasarı", x: 0.08, y: 0.29),
                annotationLine("right_r", "Apoptoz: kaspazlar", x: 0.58, y: 0.29),
            ],
            tokens: [
                annotationToken("left_r_token", "Nekroz", x: 0.12, y: 0.30),
                annotationToken("right_r_token", "Apoptoz", x: 0.62, y: 0.30),
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [left, right], groups: [markerGroup("left_g", evidence: left), markerGroup("right_g", evidence: right)],
                autoSelectedGroupIds: ["left_g", "right_g"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 2)
        XCTAssertTrue(grounded.groups.contains { $0.contextText.contains("Nekroz") })
        XCTAssertTrue(grounded.groups.contains { $0.contextText.contains("Apoptoz") })
    }

    func testManualRectangleDoesNotMergeIntoANearbyAutomaticMark() {
        let automatic = markerEvidence("auto_e", line: "v1", token: "v1t", x: 0.20, y: 0.30)
        let manualEvidence = AnnotationEvidence(
            id: "manual_e", type: .manual,
            boundingBox: NormalizedRect(x: 0.21, y: 0.335, width: 0.10, height: 0.03),
            lineIds: [], confidence: 1, decision: .userSelection
        )
        let manual = AnnotationGroup(
            id: "manual_g", evidenceIds: [manualEvidence.id], selectedLineIds: [], contextLineIds: [],
            boundingBox: manualEvidence.boundingBox, confidence: 1, needsConfirmation: false, selectionType: .manual
        )
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("r1", "Hipoksi hücre hasarı yapar.", x: 0.10, y: 0.29)],
            tokens: [annotationToken("r1_token", "Hipoksi", x: 0.20, y: 0.30)]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [automatic, manualEvidence],
                groups: [markerGroup("auto_g", evidence: automatic), manual],
                autoSelectedGroupIds: ["auto_g", "manual_g"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 2)
        XCTAssertTrue(grounded.groups.contains { $0.selectionType == .manual })
    }
}

final class PageOverlayTransformTests: XCTestCase {
    func testAspectFitZoomAndPanRoundTrip() {
        let transform = PageOverlayTransform(
            imageWidth: 1000, imageHeight: 2000,
            viewportWidth: 1000, viewportHeight: 1000,
            zoom: 1.5, panX: 30, panY: -20
        )
        let rect = transform.viewRect(for: NormalizedRect(x: 0.2, y: 0.3, width: 0.1, height: 0.1))
        guard let point = transform.normalizedPoint(viewX: rect.x + rect.width / 2, viewY: rect.y + rect.height / 2) else {
            return XCTFail("Görüntü içindeki nokta normalize edilemedi")
        }
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.35, accuracy: 0.0001)
    }
}

final class TokenMarkerDetectionTests: XCTestCase {
    func testTokenDetectionUsesItsParentLineSeparation() throws {
        let config = try MarkerConfig.bundled()
        let detector = MarkerDetector(config: config)
        let width = 120
        let height = 100
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw XCTSkip("CGContext oluşturulamadı") }
        context.setFillColor(CGColor.sRGB(1, 1, 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw XCTSkip("Görüntü üretilemedi") }
        let page = try PixelBuffer(cgImage: image)
        let tokens = [
            TokenBox(tokenId: "a", lineId: "a", x: 10, y: 20, width: 30, height: 16),
            TokenBox(tokenId: "b", lineId: "b", x: 10, y: 37, width: 30, height: 16)
        ]
        let result = detector.analyze(page: page, tokens: tokens)
        XCTAssertLessThan(result[0].detection.neighboringSeparation, 1)
    }

    func testShortUnderlineIsDetectedAtTokenLevelEvenWhenItWouldBeTinyOnTheLine() throws {
        let config = try MarkerConfig.bundled()
        let detector = MarkerDetector(config: config)
        let width = 240
        let height = 100
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
        let page = try PixelBuffer(cgImage: image)
        let token = TokenBox(tokenId: "hipoksi", lineId: "long_line", x: 90, y: 40, width: 28, height: 16, ocrConfidence: 0.99)

        let result = detector.analyze(page: page, tokens: [token], documentQuality: 0.99)
        XCTAssertEqual(result.first?.detection.selectionType, .underline)
        XCTAssertNotEqual(result.first?.detection.decision, .userSelection)
    }
}
