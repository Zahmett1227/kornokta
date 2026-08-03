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

        let candidates: [(detection: LineDetection, lineId: String, tokenId: String?, box: NormalizedRect)]
        if tokenBoxes.isEmpty {
            let lineDetections = detector.analyze(
                page: buffer,
                lines: page.lines.map { LineBox($0, imageWidth: buffer.width, imageHeight: buffer.height) },
                documentQuality: quality
            )
            let lookup = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })
            candidates = lineDetections.compactMap { detection in
                guard let line = lookup[detection.lineId] else { return nil }
                return (detection, line.id, nil, NormalizedRect(line.box))
            }
        } else {
            candidates = detector.analyze(page: buffer, tokens: tokenBoxes, documentQuality: quality).map { tokenDetection in
                let token = tokenDetection.token
                return (
                    tokenDetection.detection,
                    token.lineId,
                    token.tokenId,
                    NormalizedRect(
                        x: Double(token.x) / Double(buffer.width),
                        y: Double(token.y) / Double(buffer.height),
                        width: Double(token.width) / Double(buffer.width),
                        height: Double(token.height) / Double(buffer.height)
                    )
                )
            }
        }

        let evidence = candidates.compactMap { candidate -> AnnotationEvidence? in
            let detection = candidate.detection
            guard detection.selectionType != .none else { return nil }
            let type: AnnotationType = detection.selectionType == .highlight ? .highlight : .underline
            return AnnotationEvidence(
                id: "evidence_\(candidate.lineId)_\(candidate.tokenId ?? "line")",
                type: type,
                boundingBox: candidate.box,
                lineIds: [candidate.lineId],
                tokenIds: candidate.tokenId.map { [$0] } ?? [],
                confidence: detection.selectionConfidence,
                decision: detection.decision,
                measurements: AnnotationVisualMeasurements(
                    highlightOverlap: detection.highlightOverlap,
                    underlineDarkRatio: detection.underlineDarkRatio,
                    underlineExtentRatio: detection.underlineExtentRatio,
                    confidence: detection.selectionConfidence
                )
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
