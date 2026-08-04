import Foundation

/// Turning measurements into a decision (ANA-PLAN §9.3, §19.2).
///
/// Split out from the pixel work on purpose: this is where the subtle rules
/// live — which marks are rejected, how the score is weighted, and what makes
/// a line unsafe to auto-accept — and being pure arithmetic it can be pinned
/// against the Python reference by the shared cases in
/// `evals/shared/marker-decision-cases.json`, with no images involved.

/// Everything measured about one line, before any judgement is applied.
public struct LineMeasurement: Sendable, Equatable {
    public let lineId: String
    public let highlightOverlap: Double
    public let underline: UnderlineEvidence
    public let ocrConfidence: Double
    public let documentQuality: Double
    public let neighboringSeparation: Double
    /// Whether genuine dark printed text is still visible once
    /// highlight-coloured pixels are set aside (`MarkerDetector
    /// .hasUnderlyingDarkText`) — a saturated printed heading or design band
    /// has none, only a translucent highlighter drawn over real black ink
    /// does. Defaults to `true` so the shared Python-reference decision
    /// cases (`evals/shared/marker-decision-cases.json`, which construct this
    /// directly from raw ratios, no pixels involved) keep testing exactly the
    /// scoring formula they always have, unaffected by this later,
    /// pixel-only addition.
    public let hasUnderlyingDarkText: Bool

    public init(
        lineId: String,
        highlightOverlap: Double,
        underline: UnderlineEvidence,
        ocrConfidence: Double,
        documentQuality: Double,
        neighboringSeparation: Double,
        hasUnderlyingDarkText: Bool = true
    ) {
        self.lineId = lineId
        self.highlightOverlap = highlightOverlap
        self.underline = underline
        self.ocrConfidence = ocrConfidence
        self.documentQuality = documentQuality
        self.neighboringSeparation = neighboringSeparation
        self.hasUnderlyingDarkText = hasUnderlyingDarkText
    }
}

extension MarkerDetector {

    /// Judges one line from its measurements.
    public func judge(_ measurement: LineMeasurement) -> LineDetection {
        let underlineConfig = config.underline
        let evidence = measurement.underline
        let darkRatio = evidence.darkRatio
        let extentRatio = evidence.extentRatio

        // Two ways something that is not an underline passes the darkness and
        // extent tests: a filled dark region (shadow, graphic) is too thick,
        // and a ruled table border is thin enough to look like a pen stroke but
        // runs past the text.
        let tooThick = evidence.thicknessRatio > underlineConfig.maxComponentThicknessRatio
        let spansBeyondLine = evidence.overrunObserved
            && evidence.overrunRatio > underlineConfig.maxOutsideOverrunRatio
        let rejected = tooThick || spansBeyondLine

        let isUnderline = darkRatio >= underlineConfig.minDarkPixelRatio
            && extentRatio >= underlineConfig.minHorizontalExtentRatio
            && !rejected
        // A colour match alone is not enough (§ item 5): a printed heading or
        // a solid design band is itself the coloured ink, with no genuine
        // black text underneath it the way a real translucent highlighter
        // stroke always has.
        let isHighlight = measurement.highlightOverlap >= config.highlight.minOverlapRatio
            && measurement.hasUnderlyingDarkText

        let selectionType: SelectionKind
        let markerOverlap: Double
        let lineGeometry: Double

        if isHighlight && measurement.highlightOverlap >= darkRatio {
            selectionType = .highlight
            markerOverlap = min(1.0, measurement.highlightOverlap)
            lineGeometry = min(1.0, measurement.highlightOverlap * 1.5)
        } else if isUnderline {
            selectionType = .underline
            // A saturated underline covers only a thin band, so the dark ratio
            // is scaled up to a comparable 0–1 range before weighting.
            markerOverlap = min(1.0, darkRatio * 3.0)
            lineGeometry = extentRatio
        } else {
            selectionType = .none
            if rejected {
                // A rejected mark must not report near-perfect evidence: the
                // score has to read as "no usable marker", not "very
                // confident".
                markerOverlap = 0
                lineGeometry = 0
            } else {
                markerOverlap = max(measurement.highlightOverlap, darkRatio)
                lineGeometry = extentRatio != 0 ? extentRatio : measurement.highlightOverlap
            }
        }

        let weights = config.confidenceWeights
        let confidence = weights.markerOverlap * markerOverlap
            + weights.lineGeometry * lineGeometry
            + weights.localOCRConfidence * measurement.ocrConfidence
            + weights.documentQuality * measurement.documentQuality
            + weights.neighboringLineSeparation * measurement.neighboringSeparation

        // An underline whose margins were not visible cannot be told apart
        // from a cropped table rule, so it must not be auto-accepted however
        // high the other components score. Unknown is routed to the user, not
        // silently trusted (§19.2, P3).
        let overrunUnknown = selectionType == .underline && !evidence.overrunObserved

        let thresholds = config.decisionThresholds
        let decision: MarkerDecision
        if selectionType == .none {
            decision = .userSelection
        } else if confidence >= thresholds.autoCandidate && !overrunUnknown {
            decision = .autoCandidate
        } else if confidence >= thresholds.quickConfirm {
            decision = .quickConfirm
        } else {
            decision = .userSelection
        }

        return LineDetection(
            lineId: measurement.lineId,
            highlightOverlap: measurement.highlightOverlap,
            underlineDarkRatio: evidence.darkRatio,
            underlineExtentRatio: evidence.extentRatio,
            markerOverlap: markerOverlap,
            lineGeometry: lineGeometry,
            localOCRConfidence: measurement.ocrConfidence,
            documentQuality: measurement.documentQuality,
            neighboringSeparation: measurement.neighboringSeparation,
            // Rounded to match the reference, so the two report the same number
            // rather than differing in the last decimal place.
            selectionConfidence: (confidence * 10_000).rounded() / 10_000,
            selectionType: selectionType,
            decision: decision
        )
    }

    /// Measures and judges every line on a page.
    public func analyze(
        page buffer: PixelBuffer,
        lines: [LineBox],
        documentQuality: Double = 0.9
    ) -> [LineDetection] {
        lines.map { line in
            judge(
                LineMeasurement(
                    lineId: line.lineId,
                    highlightOverlap: highlightOverlap(in: buffer, line: line),
                    underline: underlineEvidence(in: buffer, line: line),
                    ocrConfidence: line.ocrConfidence,
                    documentQuality: documentQuality,
                    neighboringSeparation: Self.neighboringSeparation(line, among: lines),
                    hasUnderlyingDarkText: hasUnderlyingDarkText(in: buffer, line: line)
                )
            )
        }
    }

    /// Token-level counterpart of `analyze(page:lines:)`. The calibrated
    /// decision rules are deliberately reused: this adds no new threshold,
    /// only applies the existing underline/highlight measurements to a word
    /// box when Vision could provide one.
    public func analyze(
        page buffer: PixelBuffer,
        tokens: [TokenBox],
        documentQuality: Double = 0.9
    ) -> [TokenDetection] {
        let parentLines = Self.parentLines(for: tokens)
        return tokens.map { token in
            let box = token.lineBox
            let parent = parentLines[token.lineId] ?? box
            return TokenDetection(
                token: token,
                detection: judge(
                    LineMeasurement(
                        lineId: token.tokenId,
                        highlightOverlap: highlightOverlap(in: buffer, line: box),
                        underline: underlineEvidence(in: buffer, line: box),
                        ocrConfidence: token.ocrConfidence,
                        documentQuality: documentQuality,
                        neighboringSeparation: Self.neighboringSeparation(parent, among: Array(parentLines.values)),
                        hasUnderlyingDarkText: hasUnderlyingDarkText(in: buffer, line: box)
                    )
                )
            )
        }
    }

    /// Reconstruct each OCR line from its token bounds. Token detection has no
    /// separate line input, but its confidence must use the same real spacing
    /// measurement as line detection rather than a permanent perfect score.
    private static func parentLines(for tokens: [TokenBox]) -> [String: LineBox] {
        Dictionary(grouping: tokens, by: \.lineId).mapValues { members in
            let first = members[0]
            let minX = members.map(\.x).min() ?? first.x
            let minY = members.map(\.y).min() ?? first.y
            let maxX = members.map { $0.x + $0.width }.max() ?? first.x + first.width
            let maxY = members.map { $0.y + $0.height }.max() ?? first.y + first.height
            return LineBox(
                lineId: first.lineId, x: minX, y: minY,
                width: max(1, maxX - minX), height: max(1, maxY - minY),
                ocrConfidence: members.map(\.ocrConfidence).reduce(0, +) / Double(members.count)
            )
        }
    }

    /// Lines the detector is willing to select.
    ///
    /// `includePending` decides whether `quick_confirm` counts. It is off by
    /// default: §19.3 says a capture with no *detected* marker must not become
    /// a card on its own, and a pending line is exactly one the detector is
    /// unsure about.
    public static func selectedLineIds(
        _ detections: [LineDetection],
        includePending: Bool = false
    ) -> [String] {
        detections
            .filter { detection in
                switch detection.decision {
                case .autoCandidate: return true
                case .quickConfirm: return includePending
                case .userSelection: return false
                }
            }
            .map(\.lineId)
    }
}
