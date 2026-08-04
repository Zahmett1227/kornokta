import Foundation
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
#endif

/// Feeds on-device marker detection into the capture pipeline (§9, §25 Faz 2).
///
/// This is the seam `ManualSelectionOnly` was standing in for: with it
/// attached, a page whose underline is unambiguous goes straight through, and
/// only the genuinely uncertain ones reach the confirmation screen (§24.2).
///
/// It stays conservative on purpose. Pending candidates are never silently
/// selected, but they are retained in the structured result so the photo-based
/// confirmation screen can ask about the actual marked area.
public struct DetectedMarkerSelector: MarkerSelecting {
    private let detector: MarkerDetector
    private let loadImage: @Sendable (URL) -> CGImage?

    public init(
        detector: MarkerDetector,
        loadImage: @escaping @Sendable (URL) -> CGImage? = DetectedMarkerSelector.defaultImageLoader
    ) {
        self.detector = detector
        self.loadImage = loadImage
    }

    /// Convenience initializer using the bundled thresholds.
    public init() throws {
        self.init(detector: MarkerDetector(config: try MarkerConfig.bundled()))
    }

    /// The overlap bar (of the smaller box) above which a line-level fallback
    /// candidate is considered the same physical mark as an already-found
    /// token candidate, not a second one. Same "same physical area" bar
    /// `CapturePipeline.lineOverlapThreshold` and `AnnotationGrouper`'s
    /// `matchingLines` already use elsewhere in this pipeline for the same
    /// question, not a new number invented for this check.
    static let lineTokenDedupOverlap = 0.3

    public static let defaultImageLoader: @Sendable (URL) -> CGImage? = { url in
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
        #else
        return nil
        #endif
    }

    public func select(in page: RecognizedPage, imageURL: URL) async throws -> MarkerSelectionResult {
        guard
            let image = loadImage(imageURL),
            let buffer = try? PixelBuffer(cgImage: image)
        else {
            // Unreadable image: return nothing rather than throwing. The
            // pipeline reads "no selection" as "ask the user", which is the
            // right outcome — a detector that cannot see the page has no
            // opinion, and turning that into a job failure would lose a
            // capture over a decoding problem (§21.2).
            return MarkerSelectionResult()
        }

        // Page quality from the OCR's own confidence: a blurry page reads
        // poorly, and §9.3 wants that reflected in the selection score rather
        // than assumed away.
        let quality = page.lines.isEmpty
            ? 0.0
            : page.lines.map(\.confidence).reduce(0, +) / Double(page.lines.count)

        let tokenBoxes = page.lines.flatMap { line in
            line.tokens.map { TokenBox($0, lineId: line.id, imageWidth: buffer.width, imageHeight: buffer.height) }
        }
        let lineLookup = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })

        struct Candidate {
            let detection: LineDetection
            let lineId: String
            let tokenId: String?
            let box: NormalizedRect
            let provenance: AnnotationProvenance
        }

        // Token-level analysis: the finer-grained, more precise signal
        // whenever Vision produced word boxes for this page at all.
        let tokenCandidates: [Candidate] = tokenBoxes.isEmpty ? [] : detector
            .analyze(page: buffer, tokens: tokenBoxes, documentQuality: quality)
            .map { tokenDetection in
                let token = tokenDetection.token
                return Candidate(
                    detection: tokenDetection.detection,
                    lineId: token.lineId,
                    tokenId: token.tokenId,
                    box: NormalizedRect(
                        x: Double(token.x) / Double(buffer.width),
                        y: Double(token.y) / Double(buffer.height),
                        width: Double(token.width) / Double(buffer.width),
                        height: Double(token.height) / Double(buffer.height)
                    ),
                    provenance: .localToken
                )
            }

        // Line-level analysis always runs too — not only when the page has no
        // tokens at all. A page can have hundreds of Apple tokens and still
        // miss tokenizing the one physical line carrying the actual marked
        // word (Apple cannot read Turkish reliably, ADR-002); the old
        // page-wide `if tokenBoxes.isEmpty` branch meant that single untokenized
        // line got no candidate whatsoever as long as *some other* line on the
        // page had tokens. Running both passes and deduping by geometry (below)
        // instead of picking one for the whole page keeps that line's mark
        // alive as a fallback candidate.
        let rawLineCandidates: [Candidate] = detector
            .analyze(page: buffer, lines: page.lines.map { LineBox($0, imageWidth: buffer.width, imageHeight: buffer.height) }, documentQuality: quality)
            .compactMap { detection in
                guard let line = lineLookup[detection.lineId] else { return nil }
                return Candidate(detection: detection, lineId: line.id, tokenId: nil, box: NormalizedRect(line.box), provenance: .localLineFallback)
            }

        // A line candidate is redundant, not a second mark, wherever a more
        // precise token candidate already covers the same physical area —
        // matched by normalized geometry, not by line id or text, so this
        // still works if token/line ids ever diverge.
        let lineCandidates = rawLineCandidates.filter { lineCandidate in
            lineCandidate.detection.selectionType != .none && !tokenCandidates.contains { tokenCandidate in
                lineCandidate.box.overlapOfSmallerArea(with: tokenCandidate.box) >= Self.lineTokenDedupOverlap
            }
        }

        let candidates = tokenCandidates + lineCandidates

        let evidence = candidates.compactMap { candidate -> AnnotationEvidence? in
            let detection = candidate.detection
            guard detection.selectionType != .none else { return nil }
            let type: AnnotationType = detection.selectionType == .highlight ? .highlight : .underline
            // A whole recognized line is a coarser measuring window than a
            // single word box — it can average in neighbouring, unmarked
            // text — so a line-only fallback (no token corroborates it) is
            // capped at quick_confirm and never silently auto-accepted,
            // however high its raw score. Only the finer, calibrated
            // token-level measurement can reach auto_candidate on its own.
            let decision: MarkerDecision = candidate.provenance == .localLineFallback && detection.decision == .autoCandidate
                ? .quickConfirm
                : detection.decision
            return AnnotationEvidence(
                id: "evidence_\(candidate.lineId)_\(candidate.tokenId ?? "line")",
                type: type,
                boundingBox: candidate.box,
                lineIds: [candidate.lineId],
                tokenIds: candidate.tokenId.map { [$0] } ?? [],
                confidence: detection.selectionConfidence,
                decision: decision,
                measurements: AnnotationVisualMeasurements(
                    highlightOverlap: detection.highlightOverlap,
                    underlineDarkRatio: detection.underlineDarkRatio,
                    underlineExtentRatio: detection.underlineExtentRatio,
                    confidence: detection.selectionConfidence
                ),
                provenance: candidate.provenance
            )
        }

        let groups = evidence.enumerated().map { index, item in
            AnnotationGroup(
                id: "marker_group_\(index)",
                evidenceIds: [item.id],
                selectedLineIds: item.lineIds,
                contextLineIds: item.lineIds,
                selectedTokenIds: item.tokenIds,
                boundingBox: item.boundingBox,
                confidence: item.confidence,
                needsConfirmation: item.decision != .autoCandidate,
                selectionType: item.type
            )
        }
        let autoSelected = zip(groups, evidence)
            .filter { $0.1.decision == .autoCandidate }
            .map { $0.0.id }
        return MarkerSelectionResult(evidence: evidence, groups: groups, autoSelectedGroupIds: autoSelected)
    }
}
