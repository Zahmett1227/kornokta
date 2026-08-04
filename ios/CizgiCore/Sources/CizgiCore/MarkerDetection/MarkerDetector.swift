import Foundation
import CoreGraphics

/// On-device underline and highlight detection (ANA-PLAN §9).
///
/// A port of `evals/spikes/marker_detection/detector.py`, which stays the
/// reference: it is where the algorithm is calibrated against the gold set.
/// The thresholds are shared as data rather than duplicated as code, and the
/// decision rules are pinned by the cases in
/// `evals/shared/marker-decision-cases.json`, which both implementations run.
///
/// Runs on device because §24.1 wants capture to finish instantly and §19.3
/// wants the user asked immediately when nothing is found — neither can wait
/// for a network round trip. It is image processing, not a model call, so §0.8
/// puts it in deterministic code.

/// An OCR text line in pixel coordinates, top-left origin.
public struct LineBox: Sendable, Equatable {
    public let lineId: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let ocrConfidence: Double

    public init(lineId: String, x: Int, y: Int, width: Int, height: Int, ocrConfidence: Double = 0.9) {
        self.lineId = lineId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.ocrConfidence = ocrConfidence
    }

    public var x2: Int { x + width }
    public var y2: Int { y + height }

    /// Builds a pixel-space box from a normalized recognition result.
    public init(_ line: RecognizedLine, imageWidth: Int, imageHeight: Int) {
        self.init(
            lineId: line.id,
            x: Int((Double(line.box.minX) * Double(imageWidth)).rounded()),
            y: Int((Double(line.box.minY) * Double(imageHeight)).rounded()),
            width: Int((Double(line.box.width) * Double(imageWidth)).rounded()),
            height: Int((Double(line.box.height) * Double(imageHeight)).rounded()),
            ocrConfidence: line.confidence
        )
    }
}

/// A word-sized geometry target. The image-processing algorithm remains the
/// same as the calibrated line detector; only the measuring window narrows so
/// an underline under “hipoksi” does not need to cover 40% of its full line.
public struct TokenBox: Sendable, Equatable {
    public let tokenId: String
    public let lineId: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let ocrConfidence: Double

    public init(
        tokenId: String,
        lineId: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        ocrConfidence: Double = 0.9
    ) {
        self.tokenId = tokenId
        self.lineId = lineId
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.ocrConfidence = ocrConfidence
    }

    public init(_ token: RecognizedToken, lineId: String, imageWidth: Int, imageHeight: Int) {
        self.init(
            tokenId: token.id,
            lineId: lineId,
            x: Int((Double(token.box.minX) * Double(imageWidth)).rounded()),
            y: Int((Double(token.box.minY) * Double(imageHeight)).rounded()),
            width: Int((Double(token.box.width) * Double(imageWidth)).rounded()),
            height: Int((Double(token.box.height) * Double(imageHeight)).rounded()),
            ocrConfidence: token.confidence
        )
    }

    public var lineBox: LineBox {
        LineBox(
            lineId: lineId,
            x: x,
            y: y,
            width: width,
            height: height,
            ocrConfidence: ocrConfidence
        )
    }
}

public enum SelectionKind: String, Sendable, Equatable {
    case highlight
    case underline
    case none
}

public enum MarkerDecision: String, Codable, Sendable, Equatable {
    case autoCandidate = "auto_candidate"
    case quickConfirm = "quick_confirm"
    case userSelection = "user_selection"
}

public struct UnderlineEvidence: Sendable, Equatable {
    public let darkRatio: Double
    public let extentRatio: Double
    public let thicknessRatio: Double
    public let overrunRatio: Double
    /// False when no margin beside the line was visible (cropped page, line at
    /// the edge). The ratio then carries no information and must be read as
    /// "unknown", never as "no overrun".
    public let overrunObserved: Bool

    public init(
        darkRatio: Double,
        extentRatio: Double,
        thicknessRatio: Double,
        overrunRatio: Double,
        overrunObserved: Bool = true
    ) {
        self.darkRatio = darkRatio
        self.extentRatio = extentRatio
        self.thicknessRatio = thicknessRatio
        self.overrunRatio = overrunRatio
        self.overrunObserved = overrunObserved
    }
}

public struct LineDetection: Sendable, Equatable {
    public let lineId: String
    public let highlightOverlap: Double
    public let underlineDarkRatio: Double
    public let underlineExtentRatio: Double
    public let markerOverlap: Double
    public let lineGeometry: Double
    public let localOCRConfidence: Double
    public let documentQuality: Double
    public let neighboringSeparation: Double
    public let selectionConfidence: Double
    public let selectionType: SelectionKind
    public let decision: MarkerDecision

    public init(
        lineId: String,
        highlightOverlap: Double = 0,
        underlineDarkRatio: Double = 0,
        underlineExtentRatio: Double = 0,
        markerOverlap: Double,
        lineGeometry: Double,
        localOCRConfidence: Double,
        documentQuality: Double,
        neighboringSeparation: Double,
        selectionConfidence: Double,
        selectionType: SelectionKind,
        decision: MarkerDecision
    ) {
        self.lineId = lineId
        self.highlightOverlap = highlightOverlap
        self.underlineDarkRatio = underlineDarkRatio
        self.underlineExtentRatio = underlineExtentRatio
        self.markerOverlap = markerOverlap
        self.lineGeometry = lineGeometry
        self.localOCRConfidence = localOCRConfidence
        self.documentQuality = documentQuality
        self.neighboringSeparation = neighboringSeparation
        self.selectionConfidence = selectionConfidence
        self.selectionType = selectionType
        self.decision = decision
    }
}

public struct TokenDetection: Sendable, Equatable {
    public let token: TokenBox
    public let detection: LineDetection

    public init(token: TokenBox, detection: LineDetection) {
        self.token = token
        self.detection = detection
    }
}

public struct MarkerDetector: Sendable {
    public let config: MarkerConfig

    public init(config: MarkerConfig) {
        self.config = config
    }

    // MARK: - Highlight

    /// Fraction of the line box covered by highlighter-coloured pixels.
    public func highlightOverlap(in buffer: PixelBuffer, line: LineBox) -> Double {
        guard let region = PixelRegion(x: line.x, y: line.y, width: line.width, height: line.height, in: buffer) else {
            return 0
        }
        let ranges = config.hueRanges
        var matching = 0
        for row in region.y..<(region.y + region.height) {
            for column in region.x..<(region.x + region.width) {
                let (h, s, v) = buffer.hsv(x: column, y: row)
                guard s >= config.highlight.minSaturation, v >= config.highlight.minValue else { continue }
                if ranges.contains(where: { h >= $0.low && h <= $0.high }) {
                    matching += 1
                }
            }
        }
        return Double(matching) / Double(region.width * region.height)
    }

    /// How close to zero a percentage has to be to read as "essentially
    /// none", not a calibrated precision bar — this only ever *rejects* a
    /// candidate that already passed `highlight.minOverlapRatio`, it never
    /// grants a new auto-accept, so a wrong value here costs recall (a real
    /// mark misses a shortcut and still reaches manual confirmation), never
    /// precision (§0.6: this is intentionally not plumbed through
    /// `MarkerConfig`/the Python reference the way a scored weight is —
    /// tightening the geometric gate below, not the calibrated formula).
    private static let underlyingDarkTextExistenceBar = 0.01

    /// Whether `line`'s own region still shows genuine dark printed text once
    /// its highlight-coloured pixels are set aside — the visual signature of
    /// a translucent highlighter drawn over black ink (a real fosforlu kalem
    /// "metin pikselini tamamen ortadan kaldırmaz", § item 5). A saturated
    /// *printed* heading or a solid coloured design band has no separate dark
    /// component at all: every dark-looking pixel there already is the
    /// coloured ink itself, none of it is left over as plain text underneath.
    /// Reuses `darkMask`'s own per-region adaptive darkness bar rather than a
    /// new absolute brightness threshold (found via real device use,
    /// 2026-08-04: a bright printed heading such as "SJÖGREN SENDROMU" passed
    /// the plain colour/overlap gate and produced a false marker candidate).
    func hasUnderlyingDarkText(in buffer: PixelBuffer, line: LineBox) -> Bool {
        guard let region = PixelRegion(x: line.x, y: line.y, width: line.width, height: line.height, in: buffer) else {
            return false
        }
        let ranges = config.hueRanges
        let mask = darkMask(in: buffer, region: region)
        var darkNonColoredCount = 0
        for row in 0..<region.height {
            for column in 0..<region.width where mask[row][column] {
                let (h, s, v) = buffer.hsv(x: region.x + column, y: region.y + row)
                let isHighlightColored = s >= config.highlight.minSaturation && v >= config.highlight.minValue
                    && ranges.contains { h >= $0.low && h <= $0.high }
                if !isHighlightColored { darkNonColoredCount += 1 }
            }
        }
        return Double(darkNonColoredCount) / Double(region.width * region.height) >= Self.underlyingDarkTextExistenceBar
    }

    /// Tight pixel bounding box of the marked pixels within `line`'s own
    /// rectangle — the marker's actual physical extent, not the whole
    /// recognized-line rectangle a line-level (no-token) measurement is
    /// forced to use as its measuring window. `nil` when no matching pixel is
    /// found (should not happen once a caller has already confirmed
    /// `selectionType != .none`, but a caller must not force-unwrap a pixel
    /// measurement) — the caller falls back to the whole line box in that
    /// rare case, the pre-existing and already-tested behaviour, rather than
    /// crash (§3: markerBounds vs textBounds — found via real device use,
    /// 2026-08-04: a single marked word inside a long line produced a
    /// whole-paragraph-wide box because the fallback candidate had no way to
    /// say *where* in the line the mark actually was).
    public func markerPixelBounds(in buffer: PixelBuffer, line: LineBox, selectionType: SelectionKind) -> CGRect? {
        switch selectionType {
        case .highlight: return highlightPixelBounds(in: buffer, line: line)
        case .underline: return underlinePixelBounds(in: buffer, line: line)
        case .none: return nil
        }
    }

    private func highlightPixelBounds(in buffer: PixelBuffer, line: LineBox) -> CGRect? {
        guard let region = PixelRegion(x: line.x, y: line.y, width: line.width, height: line.height, in: buffer) else {
            return nil
        }
        let ranges = config.hueRanges
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        for row in region.y..<(region.y + region.height) {
            for column in region.x..<(region.x + region.width) {
                let (h, s, v) = buffer.hsv(x: column, y: row)
                guard s >= config.highlight.minSaturation, v >= config.highlight.minValue,
                      ranges.contains(where: { h >= $0.low && h <= $0.high })
                else { continue }
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Horizontal extent only: an underline's vertical position is already
    /// the measured band itself (baseline-anchored), not something a per-
    /// column pixel scan should shrink further — only *where along the line*
    /// the dark stroke starts and stops is unknown ahead of time.
    private func underlinePixelBounds(in buffer: PixelBuffer, line: LineBox) -> CGRect? {
        let underline = config.underline
        let bandHeight = max(3, Int((Double(line.height) * underline.bandHeightRatio).rounded()))
        let bandTop = line.y2 - 2
        let bandFullHeight = bandHeight + 2
        guard let band = PixelRegion(x: line.x, y: bandTop, width: line.width, height: bandFullHeight, in: buffer) else {
            return nil
        }
        let mask = darkMask(in: buffer, region: band)
        var minX = Int.max, maxX = Int.min
        for row in 0..<band.height {
            for column in 0..<band.width where mask[row][column] {
                minX = min(minX, column); maxX = max(maxX, column)
            }
        }
        guard minX <= maxX else { return nil }
        return CGRect(x: band.x + minX, y: line.y, width: maxX - minX + 1, height: line.height)
    }

    // MARK: - Underline

    /// Dark-pixel mask for a region: below the mean by two standard
    /// deviations, but never above an absolute ceiling, so a uniformly light
    /// patch does not produce "dark" pixels out of noise.
    private func darkMask(in buffer: PixelBuffer, region: PixelRegion) -> [[Bool]] {
        var values: [Double] = []
        values.reserveCapacity(region.width * region.height)
        for row in region.y..<(region.y + region.height) {
            for column in region.x..<(region.x + region.width) {
                values.append(buffer.gray(x: column, y: row))
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        let threshold = max(80.0, mean - 2.0 * variance.squareRoot())

        var mask = [[Bool]](repeating: [Bool](repeating: false, count: region.width), count: region.height)
        var index = 0
        for row in 0..<region.height {
            for column in 0..<region.width {
                mask[row][column] = values[index] < threshold
                index += 1
            }
        }
        return mask
    }

    /// Evidence for a dark horizontal mark below the text baseline.
    public func underlineEvidence(in buffer: PixelBuffer, line: LineBox) -> UnderlineEvidence {
        let underline = config.underline
        let bandHeight = max(3, Int((Double(line.height) * underline.bandHeightRatio).rounded()))
        // The band hugs the baseline: a little above, for underlines touching
        // descenders, plus the band below where they actually sit. Keeping it
        // tight avoids diluting the dark ratio for thin pencil strokes.
        let bandTop = line.y2 - 2
        let bandFullHeight = bandHeight + 2

        guard let band = PixelRegion(x: line.x, y: bandTop, width: line.width, height: bandFullHeight, in: buffer) else {
            return UnderlineEvidence(darkRatio: 0, extentRatio: 0, thicknessRatio: 0, overrunRatio: 0, overrunObserved: false)
        }

        let mask = darkMask(in: buffer, region: band)
        let darkCount = mask.reduce(0) { $0 + $1.filter { $0 }.count }
        let darkRatio = Double(darkCount) / Double(band.width * band.height)

        // Horizontal extent: fraction of columns containing a dark pixel. A
        // real underline spans most of the line; stray specks do not.
        var columnsWithDark = 0
        for column in 0..<band.width where mask.contains(where: { $0[column] }) {
            columnsWithDark += 1
        }
        let extentRatio = band.width > 0 ? Double(columnsWithDark) / Double(band.width) : 0

        // Thickness: how many consecutive rows form the wide dark stripe. An
        // underline is thin; a shadow or a filled graphic is thick.
        let wideRows = mask.map { row in
            Double(row.filter { $0 }.count) / Double(max(1, band.width)) >= underline.minHorizontalExtentRatio
        }
        let thicknessRatio = Double(Self.longestRun(wideRows)) / Double(max(1, line.height))

        let (overrunRatio, observed) = horizontalOverrun(
            in: buffer, line: line, bandTop: bandTop, bandHeight: bandFullHeight
        )

        return UnderlineEvidence(
            darkRatio: darkRatio,
            extentRatio: extentRatio,
            thicknessRatio: thicknessRatio,
            overrunRatio: overrunRatio,
            overrunObserved: observed
        )
    }

    /// How strongly the mark continues past the ends of the text line.
    ///
    /// A ruled table border or page rule runs the full column width regardless
    /// of where the text stops; a pen underline starts and ends at the text.
    /// Thickness alone cannot separate a 3px table rule from a 3px pen stroke —
    /// this can.
    ///
    /// The zone immediately beside the line is *skipped*, because a hand stroke
    /// often overhangs a tight OCR box by a little. Both distances scale with
    /// line **height**, not length: how far a stroke overshoots depends on the
    /// size of the text, not on how long the line is. Scaling by width made the
    /// tolerance on a full-width line swallow the whole page margin, and the
    /// signal was never observable.
    private func horizontalOverrun(
        in buffer: PixelBuffer,
        line: LineBox,
        bandTop: Int,
        bandHeight: Int
    ) -> (ratio: Double, observed: Bool) {
        let underline = config.underline
        let tolerance = max(2, Int((Double(line.height) * underline.penOverhangToleranceRatio).rounded()))
        let margin = max(6, Int((Double(line.height) * underline.overrunMarginRatio).rounded()))

        let sides = [
            PixelRegion(x: line.x - tolerance - margin, y: bandTop, width: margin, height: bandHeight, in: buffer),
            PixelRegion(x: line.x2 + tolerance, y: bandTop, width: margin, height: bandHeight, in: buffer),
        ]

        var coverages: [Double] = []
        for side in sides {
            // Most of the intended margin has to be on-image; a sliver gives an
            // unreliable coverage figure.
            guard let side, side.width >= margin / 2 else { continue }
            let mask = darkMask(in: buffer, region: side)
            var columns = 0
            for column in 0..<side.width where mask.contains(where: { $0[column] }) {
                columns += 1
            }
            coverages.append(Double(columns) / Double(side.width))
        }

        guard let smallest = coverages.min() else { return (0, false) }
        // Combined with min() so a mark must continue in BOTH directions to
        // read as a rule.
        return (smallest, true)
    }

    static func longestRun(_ flags: [Bool]) -> Int {
        var best = 0
        var run = 0
        for flag in flags {
            run = flag ? run + 1 : 0
            best = max(best, run)
        }
        return best
    }

    /// 1.0 when the line is well separated from its neighbours vertically,
    /// lower when one is close enough to be confused with it (§9.3).
    static func neighboringSeparation(_ line: LineBox, among others: [LineBox]) -> Double {
        var gaps: [Int] = []
        for other in others where other.lineId != line.lineId {
            if other.y >= line.y2 {
                gaps.append(other.y - line.y2)
            } else if other.y2 <= line.y {
                gaps.append(line.y - other.y2)
            }
        }
        guard let smallest = gaps.min() else { return 1.0 }
        // Normalized against line height: a gap of one line height or more is
        // fully separated.
        return min(1.0, Double(max(0, smallest)) / Double(max(1, line.height)))
    }
}
