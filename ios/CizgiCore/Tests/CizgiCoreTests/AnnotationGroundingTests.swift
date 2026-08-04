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

    /// Regression test 7: a manual box that overlaps no line at all must not
    /// be silently pinned to whatever line happens to sit nearest — it stays
    /// in the result, empty, forced to confirmation, with its bounding box
    /// intact (§0.5). Superseded 2026-08-04's nearest-line fallback, which
    /// this exact test used to assert the opposite of.
    func testManualRectangleWithNoMeaningfulOverlapStaysUnresolvedRatherThanGuessingTheNearestLine() {
        let box = NormalizedRect(x: 0.10, y: 0.335, width: 0.10, height: 0.03)
        let manual = AnnotationGroup(
            id: "manual_g", evidenceIds: [], selectedLineIds: [], contextLineIds: [],
            boundingBox: box,
            confidence: 1, needsConfirmation: false, selectionType: .manual
        )
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                annotationLine("near", "Yakın satır", x: 0.10, y: 0.30),
                annotationLine("far", "Uzak satır", x: 0.10, y: 0.80)
            ],
            tokens: []
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(groups: [manual], autoSelectedGroupIds: ["manual_g"]),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 1, "Grup kaybolmamalı")
        XCTAssertEqual(grounded.groups.first?.selectedLineIds, [])
        XCTAssertEqual(grounded.groups.first?.selectedText, "")
        // Accuracy, not exact equality: `merge`'s bounds computation round-trips
        // through `CGRect.union` even for a single-member cluster, which can
        // introduce a last-bit float difference unrelated to this behaviour.
        XCTAssertEqual(grounded.groups.first?.boundingBox.x ?? -1, box.x, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.y ?? -1, box.y, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.width ?? -1, box.width, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.height ?? -1, box.height, accuracy: 1e-9)
        XCTAssertTrue(grounded.groups.first?.needsConfirmation ?? false)
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains("manual_g"))
    }

    /// Offline counterpart of the test above (§ item 8: backend olmadan da
    /// aynı davranış).
    func testOfflineManualRectangleWithNoMeaningfulOverlapStaysUnresolvedRatherThanGuessingTheNearestLine() {
        let box = NormalizedRect(x: 0.10, y: 0.335, width: 0.10, height: 0.03)
        let manual = AnnotationGroup(
            id: "manual", evidenceIds: [], selectedLineIds: [], contextLineIds: [],
            boundingBox: box,
            confidence: 1, needsConfirmation: false, selectionType: .manual
        )
        let local = RecognizedPage(lines: [
            RecognizedLine(id: "near", text: "Yakın satır", confidence: 0.9, box: CGRect(x: 0.10, y: 0.30, width: 0.36, height: 0.04)),
            RecognizedLine(id: "far", text: "Uzak satır", confidence: 0.9, box: CGRect(x: 0.10, y: 0.80, width: 0.36, height: 0.04))
        ], elapsed: 0)

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(groups: [manual], autoSelectedGroupIds: ["manual"]),
            localPage: local, remotePage: nil
        )

        XCTAssertEqual(grounded.groups.count, 1, "Grup kaybolmamalı")
        XCTAssertEqual(grounded.groups.first?.selectedLineIds, [])
        XCTAssertEqual(grounded.groups.first?.selectedText, "")
        XCTAssertEqual(grounded.groups.first?.boundingBox.x ?? -1, box.x, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.y ?? -1, box.y, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.width ?? -1, box.width, accuracy: 1e-9)
        XCTAssertEqual(grounded.groups.first?.boundingBox.height ?? -1, box.height, accuracy: 1e-9)
        XCTAssertTrue(grounded.groups.first?.needsConfirmation ?? false)
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains("manual"))
    }
}

/// Regression tests for Google Document AI's own style signals
/// (`isUnderlined`, `backgroundColor`) becoming selectable candidates in
/// their own right, not just grounding for a pre-existing local candidate.
final class RemoteAnnotationCandidateTests: XCTestCase {
    /// Regression test 2: Apple never tokenized the marked word at all (no
    /// local evidence whatsoever), but Google's own underline flag is enough
    /// to surface a pending candidate with the correct box.
    func testGoogleUnderlineStyleAloneProducesAQuickConfirmCandidateWithNoLocalEvidence() throws {
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("g0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [
                RemoteToken(
                    tokenId: "g0_token", text: "hipoksi", confidence: 0.95,
                    x: 0.44, y: 0.20, width: 0.09, height: 0.025, isUnderlined: true
                )
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 1)
        let group = try XCTUnwrap(grounded.groups.first)
        XCTAssertEqual(group.selectionType, .underline)
        XCTAssertEqual(group.selectedText, "hipoksi")
        XCTAssertTrue(group.needsConfirmation, "Yalnız Google stil sinyali sessizce otomatik kabul edilmemeli")
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains(group.id))
        let provenances = group.evidenceIds.compactMap { id in grounded.evidence.first { $0.id == id }?.provenance }
        XCTAssertEqual(provenances, [.remoteUnderlineStyle])
    }

    /// Regression test 3: the same physical mark reaches grounding from both
    /// a local (Apple/pixel) candidate and Google's own underline flag. They
    /// must resolve to one user-facing group, and the group must stay
    /// auto-accepted (the local candidate already qualified on its own —
    /// merely being *also* corroborated by an uncalibrated style flag must
    /// not drag it back into needing confirmation), while both evidence
    /// sources remain individually recoverable.
    func testGoogleUnderlineAndLocalTokenOverTheSameAreaMergeIntoOneGroupPreservingBothProvenances() throws {
        let localEvidence = markerEvidence("local_e", line: "vision_0", token: "vision_0_t", x: 0.44, y: 0.20)
        let localGroup = markerGroup("local_g", evidence: localEvidence)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("g0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [
                RemoteToken(
                    tokenId: "g0_token", text: "hipoksi", confidence: 0.95,
                    x: 0.44, y: 0.20, width: 0.09, height: 0.025, isUnderlined: true
                )
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [localEvidence], groups: [localGroup], autoSelectedGroupIds: ["local_g"]),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 1)
        let group = try XCTUnwrap(grounded.groups.first)
        XCTAssertFalse(group.needsConfirmation, "Yerelde zaten nitelikli aday, tek başına Google stiliyle onaya düşmemeli")
        XCTAssertEqual(group.selectedText, "hipoksi")
        let provenances = Set(group.evidenceIds.compactMap { id in grounded.evidence.first { $0.id == id }?.provenance })
        XCTAssertEqual(provenances, [.localToken, .remoteUnderlineStyle])
    }

    /// Regression test 4: a printed, pastel heading/table background must not
    /// pass the same hue/saturation/value gate a real highlighter pixel has
    /// to — `backgroundColor` alone is not "fosforlu kalem".
    func testPrintedPastelBackgroundIsRejectedButGenuineHighlighterColorPasses() throws {
        let config = try MarkerConfig.bundled()
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [],
            tokens: [
                RemoteToken(
                    tokenId: "heading_token", text: "Başlığı", confidence: 0.95,
                    x: 0.12, y: 0.05, width: 0.10, height: 0.03,
                    backgroundColor: RemoteColor(red: 0.85, green: 0.87, blue: 0.93)
                ),
                RemoteToken(
                    tokenId: "marked_token", text: "bilgi", confidence: 0.95,
                    x: 0.20, y: 0.40, width: 0.10, height: 0.03,
                    backgroundColor: RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
                )
            ]
        )

        let candidates = RemoteAnnotationCandidateBuilder.build(from: page, config: config)

        XCTAssertEqual(candidates.groups.count, 1)
        XCTAssertEqual(candidates.groups.first?.selectedTokenIds, ["marked_token"])
        XCTAssertEqual(candidates.groups.first?.selectionType, .highlight)
    }

    /// Regression test 5: three remote-style highlights sit on the same row.
    /// The middle one is close enough to merge with both its neighbours
    /// individually, but the two outer ones are not close enough to each
    /// other — a transitive chain through the middle candidate must not
    /// collapse all three (or the two far ones) into a single group.
    func testTwoFarApartHighlightsOnTheSameRowDoNotChainMergeThroughAMiddleCandidate() throws {
        let config = try MarkerConfig.bundled()
        let yellow = RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [],
            tokens: [
                RemoteToken(tokenId: "left", text: "Sol", confidence: 0.95, x: 0.00, y: 0.30, width: 0.05, height: 0.03, backgroundColor: yellow),
                RemoteToken(tokenId: "middle", text: "Orta", confidence: 0.95, x: 0.25, y: 0.30, width: 0.05, height: 0.03, backgroundColor: yellow),
                RemoteToken(tokenId: "right", text: "Sağ", confidence: 0.95, x: 0.58, y: 0.30, width: 0.05, height: 0.03, backgroundColor: yellow)
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page,
            config: config
        )

        XCTAssertEqual(grounded.groups.count, 2, "Sağdaki, ortadaki köprü aday üzerinden sola zincirlenerek birleşmemeli")
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["right"]) })
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["left", "middle"]) })
    }

    /// Regression test 6 (remote-only variant of the local-only column test
    /// above): two columns' worth of Google-only underline candidates at the
    /// same row height must not merge just because they share a height.
    func testTwoColumnsOfRemoteOnlyCandidatesStaySeparate() throws {
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [],
            tokens: [
                RemoteToken(tokenId: "left_col", text: "Nekroz", confidence: 0.95, x: 0.10, y: 0.30, width: 0.08, height: 0.03, isUnderlined: true),
                RemoteToken(tokenId: "right_col", text: "Apoptoz", confidence: 0.95, x: 0.62, y: 0.30, width: 0.08, height: 0.03, isUnderlined: true)
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page
        )

        XCTAssertEqual(grounded.groups.count, 2)
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

    func testDragOutsideTheImageClampsToItsEdgeInsteadOfFailing() {
        let transform = PageOverlayTransform(
            imageWidth: 1000, imageHeight: 2000,
            viewportWidth: 1000, viewportHeight: 1000,
            zoom: 1, panX: 0, panY: 0
        )
        guard let point = transform.normalizedPoint(viewX: -500, viewY: 5000) else {
            return XCTFail("Kenar dışı bir nokta artık nil değil, kenara kenetlenmiş dönmeli")
        }
        XCTAssertEqual(point.x, 0, accuracy: 0.0001)
        XCTAssertEqual(point.y, 1, accuracy: 0.0001)
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
