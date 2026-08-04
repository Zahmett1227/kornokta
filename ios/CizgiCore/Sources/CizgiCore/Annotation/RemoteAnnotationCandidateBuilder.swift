import Foundation

/// Builds annotation candidates directly from Google Document AI's own style
/// signals (`RemoteToken.isUnderlined`, `RemoteToken.backgroundColor`) — the
/// gap this closes: those fields were already decoded off the wire, but
/// nothing produced a selectable group from them, so a marker Apple Vision
/// never saw (it cannot read Turkish reliably, ADR-002) had no way to reach
/// the confirmation screen even though Google read it correctly.
///
/// Deliberately a separate component rather than inline logic in
/// `AnnotationGrouper`: that type's job is resolving/merging candidates
/// against OCR geometry, not deciding what counts as a mark in the first
/// place (§0.8 — that judgement belongs with the other marker-decision code).
public enum RemoteAnnotationCandidateBuilder {
    /// How large a horizontal gap between two consecutive style-flagged
    /// tokens on the same line still reads as one continuous mark rather than
    /// two separate ones — ordinary word spacing, not a break. Same bar
    /// Document AI's own column-gutter detection uses server-side for "this
    /// gap is not a real break" (`documentAI.ts`'s `MIN_GUTTER_WIDTH`).
    static let sameMarkGapRatio = 0.02

    /// Recorded on a Google-style-only candidate, but purely informational:
    /// no decision anywhere branches on this number. Style flags have no
    /// gold-set calibration yet (unlike `MarkerDecisionRules`'s pixel
    /// formula), so this can never be an auto-accept threshold — the decision
    /// is unconditionally `.quickConfirm` below, never derived from a score.
    static let uncalibratedConfidence = 0.5

    /// - Parameter config: Supplies the same hue/saturation/value gate local
    ///   pixel highlight detection uses, so a printed colour (a heading bar, a
    ///   table zebra stripe) is held to the identical bar a real highlighter
    ///   pixel would need to pass — not a new, separate guess at "looks
    ///   highlighted". `nil` (config unavailable) skips backgroundColor
    ///   candidates entirely rather than inventing a fallback number;
    ///   `isUnderlined` candidates need no such gate and are unaffected.
    public static func build(from page: RemotePage, config: MarkerConfig?) -> (evidence: [AnnotationEvidence], groups: [AnnotationGroup]) {
        var tokenLineId: [String: String] = [:]
        for line in page.lines {
            for tokenId in line.tokenIds { tokenLineId[tokenId] = line.lineId }
        }

        var evidence: [AnnotationEvidence] = []
        var groups: [AnnotationGroup] = []

        appendRuns(
            page.tokens.filter(\.isUnderlined),
            tokenLineId: tokenLineId,
            type: .underline,
            provenance: .remoteUnderlineStyle,
            idPrefix: "remote_underline",
            evidence: &evidence,
            groups: &groups
        )

        if let config {
            let highlightLike = page.tokens.filter { token in
                guard let color = token.backgroundColor else { return false }
                let (hue, saturation, value) = hsv(of: color)
                guard saturation >= config.highlight.minSaturation, value >= config.highlight.minValue else { return false }
                return config.hueRanges.contains { hue >= $0.low && hue <= $0.high }
            }
            appendRuns(
                highlightLike,
                tokenLineId: tokenLineId,
                type: .highlight,
                provenance: .remoteBackgroundStyle,
                idPrefix: "remote_highlight",
                evidence: &evidence,
                groups: &groups
            )
        }

        return (evidence, groups)
    }

    /// Groups style-flagged tokens into contiguous per-line runs (a phrase,
    /// not one candidate per word) and emits one candidate group per run.
    /// Always `.quickConfirm`/`needsConfirmation`: a style flag alone is never
    /// enough to auto-accept (§19.2) — only `AnnotationGrouper.merge`'s
    /// corroboration with an already-qualified local candidate can do that.
    private static func appendRuns(
        _ tokens: [RemoteToken],
        tokenLineId: [String: String],
        type: AnnotationType,
        provenance: AnnotationProvenance,
        idPrefix: String,
        evidence: inout [AnnotationEvidence],
        groups: inout [AnnotationGroup]
    ) {
        let byLine = Dictionary(grouping: tokens) { tokenLineId[$0.tokenId] ?? $0.tokenId }
        for (lineId, lineTokens) in byLine.sorted(by: { $0.key < $1.key }) {
            let ordered = lineTokens.sorted { $0.x < $1.x }
            var runs: [[RemoteToken]] = []
            for token in ordered {
                if var last = runs.last, let previous = last.last, token.x - (previous.x + previous.width) <= sameMarkGapRatio {
                    last.append(token)
                    runs[runs.count - 1] = last
                } else {
                    runs.append([token])
                }
            }
            for (index, run) in runs.enumerated() {
                let box = run.map(\.boundingBox).reduce(run[0].boundingBox) { $0.union($1) }
                let evidenceId = "\(idPrefix)_\(lineId)_\(index)"
                let item = AnnotationEvidence(
                    id: evidenceId,
                    type: type,
                    boundingBox: box,
                    lineIds: [lineId],
                    tokenIds: run.map(\.tokenId),
                    confidence: uncalibratedConfidence,
                    decision: .quickConfirm,
                    provenance: provenance
                )
                evidence.append(item)
                groups.append(
                    AnnotationGroup(
                        id: "\(idPrefix)_group_\(lineId)_\(index)",
                        evidenceIds: [item.id],
                        selectedLineIds: [lineId],
                        contextLineIds: [lineId],
                        selectedTokenIds: run.map(\.tokenId),
                        boundingBox: box,
                        confidence: uncalibratedConfidence,
                        needsConfirmation: true,
                        selectionType: type
                    )
                )
            }
        }
    }

    /// Same OpenCV-scale conversion `PixelBuffer.hsv` uses (H 0–179, S/V
    /// 0–255) so `MarkerConfig.highlight`'s thresholds and hue ranges apply
    /// unchanged to a Document AI `RemoteColor` (0–1 floats per channel).
    private static func hsv(of color: RemoteColor) -> (h: Double, s: Double, v: Double) {
        let r = color.red * 255, g = color.green * 255, b = color.blue * 255
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum

        var hue: Double = 0
        if delta > 0 {
            if maximum == r {
                hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maximum == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }

        let saturation = maximum > 0 ? (delta / maximum) * 255 : 0
        return (hue / 2, saturation, maximum)
    }
}
