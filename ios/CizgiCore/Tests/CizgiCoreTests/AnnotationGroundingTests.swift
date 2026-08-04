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

/// Like `markerEvidence`, but with a configurable box — needed to construct
/// precise "adjacent" vs. "far apart" vs. "different line" geometries for
/// the merge-predicate tests below.
private func localTokenEvidence(
    _ id: String, line: String, token: String, x: Double, y: Double, width: Double = 0.10, height: Double = 0.03
) -> AnnotationEvidence {
    AnnotationEvidence(
        id: id, type: .underline,
        boundingBox: NormalizedRect(x: x, y: y, width: width, height: height),
        lineIds: [line], tokenIds: [token], confidence: 0.9, decision: .autoCandidate, provenance: .localToken
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

    /// Three remote-style highlights sit on the very same real OCR line —
    /// sharing one literal Google `lineId` — but with real gaps between them
    /// far beyond ordinary word spacing. Sharing a line id alone is not
    /// enough to merge (§ item 3: "aynı satırda birbirinden uzak iki ayrı
    /// fosforlu ifade tek grup olmamalı") — only genuinely adjacent runs on
    /// that line combine. This also proves complete-linkage still holds:
    /// nothing here transitively chains through a middle candidate either.
    ///
    /// (Supersedes a same-named-in-spirit test that used to assert
    /// left+middle merged into one group under the old "close horizontal
    /// center, small vertical gap" rule — that was exactly the over-eager
    /// merging this task removes; three genuinely separate marks on a row,
    /// even a shared row, must stay three separate marks.)
    func testTwoFarApartHighlightsOnTheSameLineDoNotMergeEvenThoughTheyShareALineId() throws {
        let config = try MarkerConfig.bundled()
        let yellow = RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [RemoteLine(
                lineId: "row", text: "Sol ... Orta ... Sağ", confidence: 0.97,
                x: 0.0, y: 0.30, width: 0.63, height: 0.03,
                tokenIds: ["left", "middle", "right"]
            )],
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

        XCTAssertEqual(grounded.groups.count, 3, "Aynı satırı paylaşsalar bile büyük boşlukla ayrılan üç ayrı ifade birleşmemeli")
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["left"]) })
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["middle"]) })
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["right"]) })
    }

    /// A printed, high-saturation heading band spans every token on its own
    /// line — not a marked phrase within it — and must never even reach the
    /// confirmation screen as a candidate, let alone auto-accept. This is
    /// the realistic false-positive the pastel-heading test above does not
    /// cover: real printed headings are frequently fully saturated (a bright
    /// yellow banner, not a washed-out pastel), so saturation/value alone
    /// cannot reject them — only the structural "covers the *entire* line"
    /// signal can.
    func testFullLineSpanningPrintedHeadingBackgroundIsSuppressed() throws {
        let config = try MarkerConfig.bundled()
        let yellow = RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [RemoteLine(
                lineId: "heading", text: "BÖLÜM BAŞLIĞI BURADA GÖRÜNÜR",
                confidence: 0.97, x: 0.05, y: 0.05, width: 0.70, height: 0.04,
                tokenIds: ["h0", "h1", "h2", "h3"]
            )],
            tokens: [
                RemoteToken(tokenId: "h0", text: "BÖLÜM", confidence: 0.95, x: 0.05, y: 0.05, width: 0.15, height: 0.04, backgroundColor: yellow),
                RemoteToken(tokenId: "h1", text: "BAŞLIĞI", confidence: 0.95, x: 0.21, y: 0.05, width: 0.18, height: 0.04, backgroundColor: yellow),
                RemoteToken(tokenId: "h2", text: "BURADA", confidence: 0.95, x: 0.40, y: 0.05, width: 0.16, height: 0.04, backgroundColor: yellow),
                RemoteToken(tokenId: "h3", text: "GÖRÜNÜR", confidence: 0.95, x: 0.57, y: 0.05, width: 0.18, height: 0.04, backgroundColor: yellow)
            ]
        )

        let candidates = RemoteAnnotationCandidateBuilder.build(from: page, config: config)

        XCTAssertTrue(candidates.groups.isEmpty, "Tüm satırı kaplayan basılı başlık bandı hiç aday üretmemeli")
        XCTAssertTrue(candidates.evidence.isEmpty)

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page,
            config: config
        )
        XCTAssertTrue(grounded.groups.isEmpty)
        XCTAssertTrue(grounded.autoSelectedGroupIds.isEmpty)
    }

    /// The suppression above must not sweep up a genuine short highlighted
    /// phrase that happens to share a page with a printed heading: the
    /// heading (all 4 of its line's tokens colored) is dropped, but a real
    /// two-word highlight covering only part of a longer, unrelated line
    /// still produces a normal quick_confirm candidate.
    func testFullLineSuppressionDoesNotDeleteAGenuineShortHighlightedWord() throws {
        let config = try MarkerConfig.bundled()
        let yellow = RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                RemoteLine(
                    lineId: "heading", text: "BÖLÜM BAŞLIĞI",
                    confidence: 0.97, x: 0.05, y: 0.05, width: 0.40, height: 0.04,
                    tokenIds: ["h0", "h1"]
                ),
                RemoteLine(
                    lineId: "body", text: "Hücre hasarının en sık sebebi hipoksidir.",
                    confidence: 0.97, x: 0.10, y: 0.30, width: 0.60, height: 0.03,
                    tokenIds: ["b0", "b1", "b2", "b3", "b4", "b5"]
                )
            ],
            tokens: [
                RemoteToken(tokenId: "h0", text: "BÖLÜM", confidence: 0.95, x: 0.05, y: 0.05, width: 0.15, height: 0.04, backgroundColor: yellow),
                RemoteToken(tokenId: "h1", text: "BAŞLIĞI", confidence: 0.95, x: 0.21, y: 0.05, width: 0.18, height: 0.04, backgroundColor: yellow),
                RemoteToken(tokenId: "b0", text: "Hücre", confidence: 0.95, x: 0.10, y: 0.30, width: 0.09, height: 0.03),
                RemoteToken(tokenId: "b1", text: "hasarının", confidence: 0.95, x: 0.20, y: 0.30, width: 0.09, height: 0.03),
                RemoteToken(tokenId: "b2", text: "en", confidence: 0.95, x: 0.30, y: 0.30, width: 0.04, height: 0.03),
                RemoteToken(tokenId: "b3", text: "sık", confidence: 0.95, x: 0.35, y: 0.30, width: 0.04, height: 0.03),
                RemoteToken(tokenId: "b4", text: "sebebi", confidence: 0.95, x: 0.40, y: 0.30, width: 0.08, height: 0.03),
                RemoteToken(tokenId: "b5", text: "hipoksidir", confidence: 0.95, x: 0.49, y: 0.30, width: 0.10, height: 0.03, backgroundColor: yellow)
            ]
        )

        let candidates = RemoteAnnotationCandidateBuilder.build(from: page, config: config)

        XCTAssertEqual(candidates.groups.count, 1, "Yalnız gerçek kısa fosforlu kelime hayatta kalmalı, başlık bastırılmalı")
        XCTAssertEqual(candidates.groups.first?.selectedTokenIds, ["b5"])
    }

    /// A backgroundColor signal alone — no local pixel/token evidence at
    /// all, no design-band suppression triggered — must still never exceed
    /// quick_confirm: there is no gold-set calibration behind the color
    /// gate yet (unlike the pixel formula), so a color match alone can never
    /// read as confident.
    func testBackgroundColorOnlySignalIsCappedAtQuickConfirmAndNeverAutoSelected() throws {
        let config = try MarkerConfig.bundled()
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("g0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [
                RemoteToken(
                    tokenId: "g0_token", text: "hipoksi", confidence: 0.95,
                    x: 0.44, y: 0.20, width: 0.09, height: 0.025,
                    backgroundColor: RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
                )
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page,
            config: config
        )

        XCTAssertEqual(grounded.groups.count, 1)
        let group = try XCTUnwrap(grounded.groups.first)
        XCTAssertTrue(group.needsConfirmation, "Yalnız backgroundColor sinyali quick_confirm'i aşmamalı")
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains(group.id))
    }

    /// A remote backgroundColor candidate over the same area as a *local*
    /// candidate must not auto-accept unless that local candidate was
    /// itself already qualified (auto-worthy) on its own — mere presence of
    /// some local evidence is not "corroboration" if that evidence was
    /// itself uncertain (e.g. a line-level fallback, not a calibrated token
    /// measurement).
    func testBackgroundColorNotCorroboratedByAQualifiedLocalMarkerNeverAutoAccepts() throws {
        let config = try MarkerConfig.bundled()
        let uncertainLocalEvidence = AnnotationEvidence(
            id: "local_e", type: .highlight,
            boundingBox: NormalizedRect(x: 0.44, y: 0.20, width: 0.09, height: 0.025),
            lineIds: ["vision_0"], tokenIds: [], confidence: 0.4, decision: .quickConfirm,
            provenance: .localLineFallback
        )
        let uncertainLocalGroup = AnnotationGroup(
            id: "local_g", evidenceIds: [uncertainLocalEvidence.id],
            selectedLineIds: uncertainLocalEvidence.lineIds, contextLineIds: uncertainLocalEvidence.lineIds,
            selectedTokenIds: [], boundingBox: uncertainLocalEvidence.boundingBox,
            confidence: uncertainLocalEvidence.confidence, needsConfirmation: true, selectionType: .highlight
        )
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("g0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [
                RemoteToken(
                    tokenId: "g0_token", text: "hipoksi", confidence: 0.95,
                    x: 0.44, y: 0.20, width: 0.09, height: 0.025,
                    backgroundColor: RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
                )
            ]
        )

        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [uncertainLocalEvidence], groups: [uncertainLocalGroup], autoSelectedGroupIds: []),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page,
            config: config
        )

        XCTAssertEqual(grounded.groups.count, 1, "Aynı fiziksel alan tek gruba birleşmeli")
        let group = try XCTUnwrap(grounded.groups.first)
        XCTAssertTrue(group.needsConfirmation, "Nitelikli olmayan yerel kanıt, backgroundColor sinyalini otomatik kabule taşımamalı")
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains(group.id))
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

/// Regression tests for `AnnotationGrouper.diagnostics` — the privacy-safe,
/// counts-only trace that lets a real-device run be told apart along "style
/// feature never requested" vs. "requested but found zero" (§7.3: counts
/// only, never OCR text).
final class AnnotationGroundingDiagnosticsTests: XCTestCase {
    func testCountsReflectRemoteTokensAndCandidatesByProvenance() throws {
        let yellow = RemoteColor(red: 1.0, green: 1.0, blue: 0.0)
        let localEvidence = markerEvidence("local_e", line: "vision_0", token: "vision_0_t", x: 0.44, y: 0.20)
        let localGroup = markerGroup("local_g", evidence: localEvidence)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [annotationLine("g0", "Hücre hasarının en sık sebebi hipoksidir.", x: 0.10, y: 0.19)],
            tokens: [
                RemoteToken(
                    tokenId: "g0_token", text: "hipoksi", confidence: 0.95,
                    x: 0.44, y: 0.20, width: 0.09, height: 0.025, isUnderlined: true
                ),
                RemoteToken(
                    tokenId: "note_token", text: "not", confidence: 0.9,
                    x: 0.80, y: 0.20, width: 0.08, height: 0.03,
                    isHandwritten: true, backgroundColor: yellow
                )
            ]
        )
        let initialSelection = MarkerSelectionResult(evidence: [localEvidence], groups: [localGroup], autoSelectedGroupIds: ["local_g"])
        let config = try MarkerConfig.bundled()
        let grounded = AnnotationGrouper.ground(
            selection: initialSelection, localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: page, config: config
        )

        let diagnostics = AnnotationGrouper.diagnostics(
            initialSelection: initialSelection, groundedSelection: grounded, remotePage: page,
            styleInfoRequested: true, groundingPhase: .initialDetection
        )

        XCTAssertEqual(diagnostics.groundingPhase, .initialDetection)
        XCTAssertTrue(diagnostics.styleInfoRequested)
        XCTAssertEqual(diagnostics.remoteTokenCount, 2)
        XCTAssertEqual(diagnostics.remoteUnderlinedTokenCount, 1)
        XCTAssertEqual(diagnostics.remoteBackgroundColorTokenCount, 1)
        XCTAssertEqual(diagnostics.remoteHandwrittenTokenCount, 1)
        XCTAssertEqual(diagnostics.localTokenCandidateCount, 1)
        XCTAssertEqual(diagnostics.localLineFallbackCandidateCount, 0)
        XCTAssertEqual(diagnostics.remoteUnderlineCandidateCount, 1)
        XCTAssertEqual(diagnostics.remoteBackgroundCandidateCount, 1)
        XCTAssertEqual(diagnostics.evidenceCountsByProvenance["local_token"], 1)
        XCTAssertEqual(diagnostics.evidenceCountsByProvenance["remote_underline_style"], 1)
        XCTAssertEqual(diagnostics.evidenceCountsByProvenance["remote_background_style"], 1)
    }

    func testZeroRemoteStyleCountsWithStyleInfoRequestedFalseMeansNeverAskedNotFoundNothing() {
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [], tokens: [RemoteToken(tokenId: "t", text: "kelime", confidence: 0.9, x: 0.1, y: 0.1, width: 0.1, height: 0.03)]
        )
        let diagnostics = AnnotationGrouper.diagnostics(
            initialSelection: MarkerSelectionResult(),
            groundedSelection: AnnotationGrouper.ground(selection: MarkerSelectionResult(), localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page),
            remotePage: page,
            styleInfoRequested: false,
            groundingPhase: .snapshotResume
        )
        XCTAssertEqual(diagnostics.groundingPhase, .snapshotResume)
        XCTAssertFalse(diagnostics.styleInfoRequested, "false ise sıfır sayılar 'hiç istenmedi' anlamına gelmeli, 'aranıp bulunamadı' değil")
        XCTAssertEqual(diagnostics.remoteUnderlineCandidateCount, 0)
        XCTAssertEqual(diagnostics.remoteBackgroundCandidateCount, 0)
    }
}

/// Regression tests for the merge rewrite (real-device trace, 2026-08-04):
/// 93 local token candidates collapsed into 26 groups spanning whole
/// paragraphs and table rows. These lock in the replacement rule — same
/// engine + same literal line + ordinary word spacing merges into one run;
/// everything else (a different line, a different engine, a large gap)
/// stays separate, regardless of vertical proximity.
final class SameLineMergeTests: XCTestCase {
    /// Regression test 1: two adjacent underlined words on the same Apple
    /// line combine into one run.
    func testAdjacentLocalTokensOnTheSameLineMergeIntoOneRun() {
        let a = localTokenEvidence("a", line: "v0", token: "a_t", x: 0.10, y: 0.20, width: 0.08)
        // Gap of 0.005 — ordinary word spacing, well under sameMarkGapRatio.
        let b = localTokenEvidence("b", line: "v0", token: "b_t", x: 0.185, y: 0.20, width: 0.08)
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [a, b], groups: [markerGroup("ga", evidence: a), markerGroup("gb", evidence: b)],
                autoSelectedGroupIds: ["ga", "gb"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: RemotePage(imageWidth: 1000, imageHeight: 1600, elapsedMs: 1, lines: [], tokens: [])
        )
        XCTAssertEqual(grounded.groups.count, 1, "Aynı satırdaki bitişik iki token tek run'a birleşmeli")
        XCTAssertEqual(Set(grounded.groups.first?.evidenceIds ?? []), ["a", "b"])
    }

    /// Regression test 2: two underlined phrases far apart on the same
    /// Apple line stay separate — sharing a line id is not enough on its own.
    func testFarApartLocalTokensOnTheSameLineStaySeparate() {
        let a = localTokenEvidence("a", line: "v0", token: "a_t", x: 0.10, y: 0.20, width: 0.08)
        let b = localTokenEvidence("b", line: "v0", token: "b_t", x: 0.60, y: 0.20, width: 0.08)
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [a, b], groups: [markerGroup("ga", evidence: a), markerGroup("gb", evidence: b)],
                autoSelectedGroupIds: ["ga", "gb"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: RemotePage(imageWidth: 1000, imageHeight: 1600, elapsedMs: 1, lines: [], tokens: [])
        )
        XCTAssertEqual(grounded.groups.count, 2, "Aynı satırı paylaşsalar bile büyük boşlukla ayrılan iki ifade birleşmemeli")
    }

    /// Regression test 3: two different OCR lines never merge just because
    /// they sit vertically close — the exact case the old center-distance/
    /// vertical-gap rule got wrong.
    func testDifferentLinesDoNotMergeEvenWhenVerticallyClose() {
        let a = localTokenEvidence("a", line: "line1", token: "a_t", x: 0.10, y: 0.20, width: 0.08, height: 0.03)
        // Starts right where `a` ends — well within the old rule's 0.045
        // vertical-gap tolerance, but a genuinely different recognized line.
        let b = localTokenEvidence("b", line: "line2", token: "b_t", x: 0.10, y: 0.235, width: 0.08, height: 0.03)
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [a, b], groups: [markerGroup("ga", evidence: a), markerGroup("gb", evidence: b)],
                autoSelectedGroupIds: ["ga", "gb"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: RemotePage(imageWidth: 1000, imageHeight: 1600, elapsedMs: 1, lines: [], tokens: [])
        )
        XCTAssertEqual(grounded.groups.count, 2, "Farklı satırlar dikey olarak yakın diye birleşmemeli")
    }

    /// Regression test 4: three consecutive lines never collapse into one
    /// giant group, whether via a single pairwise rule or a transitive chain
    /// through complete-linkage.
    func testThreeConsecutiveLinesNeverCollapseIntoOneGroup() {
        let a = localTokenEvidence("a", line: "line1", token: "a_t", x: 0.10, y: 0.20, width: 0.08, height: 0.03)
        let b = localTokenEvidence("b", line: "line2", token: "b_t", x: 0.10, y: 0.235, width: 0.08, height: 0.03)
        let c = localTokenEvidence("c", line: "line3", token: "c_t", x: 0.10, y: 0.27, width: 0.08, height: 0.03)
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [a, b, c],
                groups: [markerGroup("ga", evidence: a), markerGroup("gb", evidence: b), markerGroup("gc", evidence: c)],
                autoSelectedGroupIds: ["ga", "gb", "gc"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0),
            remotePage: RemotePage(imageWidth: 1000, imageHeight: 1600, elapsedMs: 1, lines: [], tokens: [])
        )
        XCTAssertEqual(grounded.groups.count, 3, "Üç ardışık satır tek dev grup olmamalı")
    }

    /// Regression test 6: a heading line and the marked item below it stay
    /// separate groups — merely being the nearest line above does not make
    /// them one unit. `parentHeading` (a separate, pre-existing mechanism)
    /// still correctly labels the item's heading, unaffected by the merge fix.
    func testHeadingAndItemBelowStaySeparateGroups() throws {
        let heading = localTokenEvidence("h", line: "heading_line", token: "h_t", x: 0.10, y: 0.05, width: 0.30, height: 0.03)
        let item = localTokenEvidence("i", line: "item_line", token: "i_t", x: 0.10, y: 0.09, width: 0.30, height: 0.03)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                RemoteLine(lineId: "heading_g", text: "Bölüm Başlığı", confidence: 0.97, x: 0.10, y: 0.05, width: 0.30, height: 0.03, tokenIds: ["h_gt"]),
                RemoteLine(lineId: "item_g", text: "Madde", confidence: 0.97, x: 0.10, y: 0.09, width: 0.30, height: 0.03, tokenIds: ["i_gt"])
            ],
            tokens: [
                RemoteToken(tokenId: "h_gt", text: "Bölüm Başlığı", confidence: 0.9, x: 0.10, y: 0.05, width: 0.30, height: 0.03),
                RemoteToken(tokenId: "i_gt", text: "Madde", confidence: 0.9, x: 0.10, y: 0.09, width: 0.30, height: 0.03)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [heading, item], groups: [markerGroup("hg", evidence: heading), markerGroup("ig", evidence: item)],
                autoSelectedGroupIds: ["hg", "ig"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        XCTAssertEqual(grounded.groups.count, 2, "Başlık ile altındaki madde ayrı kalmalı")
        let itemGroup = try XCTUnwrap(grounded.groups.first { $0.selectedText == "Madde" })
        XCTAssertEqual(itemGroup.parentHeading, "Bölüm Başlığı")
    }

    /// Regression test 7: a marker inside a table region and one outside it
    /// do not merge just because they sit close vertically.
    func testMarkerInsideAndOutsideATableDoNotMerge() {
        let inside = localTokenEvidence("in", line: "table_line", token: "in_t", x: 0.20, y: 0.52, width: 0.10, height: 0.03)
        let outside = localTokenEvidence("out", line: "para_line", token: "out_t", x: 0.20, y: 0.48, width: 0.10, height: 0.03)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [], tokens: [],
            tables: [RemoteLayoutRegion(id: "t1", kind: .tableCandidate, text: "", confidence: 0.9, x: 0.15, y: 0.50, width: 0.70, height: 0.20)]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [inside, outside], groups: [markerGroup("ing", evidence: inside), markerGroup("outg", evidence: outside)],
                autoSelectedGroupIds: ["ing", "outg"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        XCTAssertEqual(grounded.groups.count, 2, "Tablo içi ve tablo dışı marker birleşmemeli")
    }

    /// Regression test 9: a large `localLineFallback` box sitting over two
    /// genuinely separate remote runs must not swallow both into one union —
    /// it bridges two mutually-unrelated marks, so it stays its own separate
    /// candidate instead (§ `isAmbiguousBridge`), and the two runs remain
    /// independently available exactly as Google reported them.
    func testLargeLocalLineFallbackDoesNotSwallowTwoSeparateRemoteRuns() throws {
        let config = try MarkerConfig.bundled()
        let fallbackEvidence = AnnotationEvidence(
            id: "fallback_e", type: .underline,
            boundingBox: NormalizedRect(x: 0.05, y: 0.20, width: 0.85, height: 0.04),
            lineIds: ["marked_line"], tokenIds: [], confidence: 0.5, decision: .quickConfirm, provenance: .localLineFallback
        )
        let fallbackGroup = AnnotationGroup(
            id: "fallback_g", evidenceIds: [fallbackEvidence.id], selectedLineIds: fallbackEvidence.lineIds, contextLineIds: fallbackEvidence.lineIds,
            boundingBox: fallbackEvidence.boundingBox, confidence: fallbackEvidence.confidence, needsConfirmation: true, selectionType: .underline
        )
        let yellow = RemoteColor(red: 1, green: 1, blue: 0)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [RemoteLine(lineId: "g0", text: "birinci ... ikinci", confidence: 0.97, x: 0.05, y: 0.205, width: 0.85, height: 0.025, tokenIds: ["a", "b"])],
            tokens: [
                RemoteToken(tokenId: "a", text: "birinci", confidence: 0.95, x: 0.10, y: 0.205, width: 0.08, height: 0.025, backgroundColor: yellow),
                RemoteToken(tokenId: "b", text: "ikinci", confidence: 0.95, x: 0.60, y: 0.205, width: 0.08, height: 0.025, backgroundColor: yellow)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [fallbackEvidence], groups: [fallbackGroup], autoSelectedGroupIds: []),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page, config: config
        )

        XCTAssertEqual(grounded.groups.count, 3, "Fallback ne 'a' ne 'b' ile birleşmemeli; üçü de ayrı kalmalı")
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["a"]) })
        XCTAssertTrue(grounded.groups.contains { Set($0.selectedTokenIds) == Set(["b"]) })
        XCTAssertFalse(grounded.autoSelectedGroupIds.contains { id in
            grounded.groups.first { $0.id == id }?.evidenceIds.contains(fallbackEvidence.id) ?? false
        })
    }
}

/// Regression tests for handwriting no longer being auto-attached to a
/// nearby printed group by proximity (§ item 6/11–14) — it stays a
/// standalone, same-line-run note candidate until a future, explicit
/// user action (Prompt 3) attaches it to something.
final class HandwritingGroupingTests: XCTestCase {
    /// Regression test 11: a handwritten note sitting close to a printed
    /// marked group is never folded into that group automatically.
    func testHandwritingIsNotAutoAttachedToANearbyPrintedGroup() throws {
        let evidence = markerEvidence("e", line: "vision_0", token: "vision_0_t", x: 0.20, y: 0.20)
        let base = markerGroup("group", evidence: evidence)
        let page = RemotePage(
            imageWidth: 100, imageHeight: 100, elapsedMs: 1,
            lines: [annotationLine("remote", "Seçili bilgi", x: 0.1, y: 0.19)],
            tokens: [
                annotationToken("text", "bilgi", x: 0.2, y: 0.2),
                // Well within the old 0.16-normalized-radius auto-attach
                // distance of `base`'s center.
                RemoteToken(tokenId: "note", text: "not", confidence: 0.8, x: 0.24, y: 0.21, width: 0.06, height: 0.03, isHandwritten: true)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(evidence: [evidence], groups: [base], autoSelectedGroupIds: ["group"]),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        let printedGroup = try XCTUnwrap(grounded.groups.first { $0.selectionType != .handwriting })
        XCTAssertEqual(printedGroup.handwrittenNoteIds, [], "El yazısı yakın basılı gruba otomatik bağlanmamalı")
        XCTAssertTrue(grounded.groups.contains { $0.selectionType == .handwriting && $0.handwrittenNoteIds == ["note"] })
    }

    /// Regression test 12: adjacent handwritten tokens on the same physical
    /// line become one standalone note, not one purple box per word.
    func testAdjacentHandwrittenTokensOnTheSameLineFormOneStandaloneNote() {
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [RemoteLine(lineId: "note_line", text: "kenar notu", confidence: 0.9, x: 0.70, y: 0.40, width: 0.20, height: 0.03, tokenIds: ["w1", "w2"])],
            tokens: [
                RemoteToken(tokenId: "w1", text: "kenar", confidence: 0.9, x: 0.70, y: 0.40, width: 0.09, height: 0.03, isHandwritten: true),
                RemoteToken(tokenId: "w2", text: "notu", confidence: 0.9, x: 0.795, y: 0.40, width: 0.08, height: 0.03, isHandwritten: true)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(), localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        let handwriting = grounded.groups.filter { $0.selectionType == .handwriting }
        XCTAssertEqual(handwriting.count, 1, "Aynı satırdaki bitişik el yazısı tokenları tek not olmalı, kelime başına kutu değil")
        XCTAssertEqual(Set(handwriting.first?.handwrittenNoteIds ?? []), ["w1", "w2"])
    }

    /// Regression test 13: two handwritten notes on different lines stay
    /// separate — not merged into one giant purple box.
    func testTwoDifferentHandwritingNotesStaySeparate() {
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                RemoteLine(lineId: "note1", text: "ilk not", confidence: 0.9, x: 0.70, y: 0.20, width: 0.15, height: 0.03, tokenIds: ["n1"]),
                RemoteLine(lineId: "note2", text: "ikinci not", confidence: 0.9, x: 0.70, y: 0.60, width: 0.15, height: 0.03, tokenIds: ["n2"])
            ],
            tokens: [
                RemoteToken(tokenId: "n1", text: "ilk", confidence: 0.9, x: 0.70, y: 0.20, width: 0.10, height: 0.03, isHandwritten: true),
                RemoteToken(tokenId: "n2", text: "ikinci", confidence: 0.9, x: 0.70, y: 0.60, width: 0.10, height: 0.03, isHandwritten: true)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(), localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        let handwriting = grounded.groups.filter { $0.selectionType == .handwriting }
        XCTAssertEqual(handwriting.count, 2, "Farklı satırlardaki iki el yazısı notu ayrı kalmalı")
    }

    /// Regression test 14: the same handwritten token never appears inside
    /// more than one printed group's `handwrittenNoteIds` — trivially true
    /// now that proximity-based attachment is gone, but locked in as an
    /// explicit regression rather than an incidental consequence.
    func testTheSameHandwritingNoteIsNotDuplicatedAcrossTwoPrintedGroups() {
        let left = markerEvidence("left_e", line: "left", token: "left_t", x: 0.10, y: 0.30)
        let right = markerEvidence("right_e", line: "right", token: "right_t", x: 0.10, y: 0.60)
        let page = RemotePage(
            imageWidth: 1000, imageHeight: 1600, elapsedMs: 1,
            lines: [
                annotationLine("left_r", "Sol bilgi", x: 0.10, y: 0.30),
                annotationLine("right_r", "Sağ bilgi", x: 0.10, y: 0.60)
            ],
            tokens: [
                annotationToken("left_r_token", "Sol", x: 0.10, y: 0.30),
                annotationToken("right_r_token", "Sağ", x: 0.10, y: 0.60),
                // Sits roughly between the two printed groups.
                RemoteToken(tokenId: "note", text: "not", confidence: 0.9, x: 0.10, y: 0.45, width: 0.08, height: 0.03, isHandwritten: true)
            ]
        )
        let grounded = AnnotationGrouper.ground(
            selection: MarkerSelectionResult(
                evidence: [left, right], groups: [markerGroup("left_g", evidence: left), markerGroup("right_g", evidence: right)],
                autoSelectedGroupIds: ["left_g", "right_g"]
            ),
            localPage: RecognizedPage(lines: [], elapsed: 0), remotePage: page
        )
        let printedGroups = grounded.groups.filter { $0.selectionType != .handwriting }
        XCTAssertTrue(printedGroups.allSatisfy { !$0.handwrittenNoteIds.contains("note") })
        let noteOwners = grounded.groups.filter { $0.handwrittenNoteIds.contains("note") }
        XCTAssertEqual(noteOwners.count, 1, "Aynı el yazısı notu ikinci kez başka bir grupta tekrarlanmamalı")
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
