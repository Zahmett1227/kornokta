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

public enum SelectionKind: String, Sendable, Equatable {
    case highlight
    case underline
    case none
}

public enum MarkerDecision: String, Sendable, Equatable {
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
    public let markerOverlap: Double
    public let lineGeometry: Double
    public let localOCRConfidence: Double
    public let documentQuality: Double
    public let neighboringSeparation: Double
    public let selectionConfidence: Double
    public let selectionType: SelectionKind
    public let decision: MarkerDecision
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
