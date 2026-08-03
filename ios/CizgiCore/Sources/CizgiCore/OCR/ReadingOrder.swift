import Foundation

/// Orders OCR lines the way a human reads the page: top to bottom, and column
/// by column rather than row by row when the page is split into columns (e.g.
/// a Nekroz/Apoptoz comparison list). Framework-agnostic — no `Vision` or
/// Document AI type here — so both `VisionTextRecognizer` and the backend's
/// `documentAI.ts` can be kept to the same behavior and this logic can be
/// tested without a real recognizer.
///
/// Reading a two-column page row by row across both columns merges two
/// unrelated sentences into one garbled line — that was a real, reported bug
/// (a Nekroz/Apoptoz comparison card whose "back" read as neither).
///
/// Kept identical to `backend/providers/documentAI.ts`'s `orderByReadingPosition`
/// / `columnBoundaries` — same constants, same algorithm — so cloud OCR and
/// local OCR do not silently diverge on how they read a column layout.
enum ReadingOrder {
    /// A line's box, top-left origin, normalized to the page (0–1).
    struct Box: Equatable {
        let minX: Double
        let minY: Double
        let maxX: Double
        let maxY: Double
    }

    /// Height of one vertical ordering band, as a fraction of the page.
    ///
    /// Quantized into bands instead of compared with a tolerance: a tolerance
    /// comparison is not a strict weak ordering — `a ≈ b` and `b ≈ c` can hold
    /// while `a < c` does too — and `sorted(by:)` given such a predicate
    /// returns an arbitrary permutation, which on a dense page scrambles the
    /// transcript. Rounding to a band is transitive.
    static let bandHeight = 0.01

    /// Buckets used to scan for column gutters in `columnBoundaries(for:)`.
    static let columnBuckets = 100
    /// A gutter narrower than this fraction of the page width is ordinary word
    /// spacing, not a column break.
    static let minGutterWidth = 0.02
    /// A gutter this close to either edge is a margin, not a break between
    /// columns of text.
    static let columnEdgeMargin = 0.08
    /// Every column a detected gutter implies must end up with at least this
    /// many lines, or the "gutter" was probably one short/indented line, not
    /// a layout.
    static let minLinesPerColumn = 2
    /// Two candidate columns must share at least this fraction of the shorter
    /// one's vertical extent, or they are not side by side — they are two
    /// horizontally-separated but vertically-stacked regions (e.g. a
    /// right-aligned header above unrelated left-aligned body text), and
    /// reading them column by column would reorder the page instead of
    /// fixing it.
    static let minVerticalOverlap = 0.5

    /// True if `box`'s span crosses one of `boundaries` rather than sitting
    /// entirely inside one column — a header or footer spanning the gutter.
    private static func spansAGutter(_ box: Box, boundaries: [Double]) -> Bool {
        boundaries.contains { boundary in box.minX < boundary && box.maxX > boundary }
    }

    private static func columnIndex(_ box: Box, boundaries: [Double]) -> Int {
        let center = (box.minX + box.maxX) / 2
        return boundaries.filter { $0 < center }.count
    }

    /// The vertical [top, bottom] extent covered by `boxes`, or `nil` if empty.
    private static func verticalRange(_ boxes: [Box]) -> (top: Double, bottom: Double)? {
        guard let top = boxes.map(\.minY).min(), let bottom = boxes.map(\.maxY).max() else { return nil }
        return (top, bottom)
    }

    /// Whether two groups of boxes coexist over a meaningful shared vertical
    /// range, rather than one sitting entirely above the other.
    private static func overlapsVertically(_ a: [Box], _ b: [Box]) -> Bool {
        guard let rangeA = verticalRange(a), let rangeB = verticalRange(b) else { return false }
        let overlap = min(rangeA.bottom, rangeB.bottom) - max(rangeA.top, rangeB.top)
        let smallerSpan = min(rangeA.bottom - rangeA.top, rangeB.bottom - rangeB.top)
        guard smallerSpan > 0 else { return false }
        return overlap / smallerSpan >= minVerticalOverlap
    }

    /// Returns `boxes`' indices in reading order.
    ///
    /// A box spanning the gutter (a header or footer) is not assigned to
    /// either column: it is placed in the overall top-to-bottom sequence,
    /// flushing whatever each column has accumulated so far (in column order)
    /// immediately before it. That puts a header before both columns, a
    /// footer after both, and a mid-page divider between whatever came above
    /// it and below it — instead of always sorting into one column by its
    /// center, which could otherwise strand a footer between the columns it
    /// actually follows.
    static func order(_ boxes: [Box]) -> [Int] {
        func band(_ box: Box) -> Int { Int((box.minY / bandHeight).rounded()) }
        func withinColumn(_ lhs: Int, _ rhs: Int) -> Bool {
            let a = boxes[lhs], b = boxes[rhs]
            let bandA = band(a), bandB = band(b)
            if bandA != bandB { return bandA < bandB }
            return a.minX < b.minX
        }

        let ordered = Array(boxes.indices).sorted(by: withinColumn)
        let boundaries = columnBoundaries(for: boxes)
        guard !boundaries.isEmpty else { return ordered }

        var buffers = [[Int]](repeating: [], count: boundaries.count + 1)
        var result: [Int] = []
        for index in ordered {
            if spansAGutter(boxes[index], boundaries: boundaries) {
                buffers.forEach { result.append(contentsOf: $0) }
                buffers = [[Int]](repeating: [], count: boundaries.count + 1)
                result.append(index)
            } else {
                buffers[columnIndex(boxes[index], boundaries: boundaries)].append(index)
            }
        }
        buffers.forEach { result.append(contentsOf: $0) }
        return result
    }

    /// Finds x-positions of vertical whitespace gutters wide and central
    /// enough to be column breaks rather than ordinary margins.
    ///
    /// A handful of full-width outliers (a header, a page number) are
    /// tolerated — `crossingTolerance` — rather than blocking detection
    /// outright, and excluded from the per-column checks below (they are not
    /// evidence for or against a column split, since they belong to neither
    /// column).
    static func columnBoundaries(for boxes: [Box]) -> [Double] {
        guard boxes.count >= 2 * minLinesPerColumn else { return [] }

        var coverage = [Int](repeating: 0, count: columnBuckets)
        for box in boxes {
            let start = max(0, Int((box.minX * Double(columnBuckets)).rounded(.down)))
            let end = min(columnBuckets, Int((box.maxX * Double(columnBuckets)).rounded(.up)))
            guard start < end else { continue }
            for bucket in start..<end { coverage[bucket] += 1 }
        }

        let crossingTolerance = max(1, boxes.count / 20)
        var boundaries: [Double] = []
        var index = 0
        while index < columnBuckets {
            guard coverage[index] <= crossingTolerance else { index += 1; continue }
            let start = index
            while index < columnBuckets, coverage[index] <= crossingTolerance { index += 1 }
            let width = Double(index - start) / Double(columnBuckets)
            let center = (Double(start) + Double(index)) / 2 / Double(columnBuckets)
            if width >= minGutterWidth, center >= columnEdgeMargin, center <= 1 - columnEdgeMargin {
                boundaries.append(center)
            }
        }

        guard !boundaries.isEmpty else { return [] }

        var perColumn = [[Box]](repeating: [], count: boundaries.count + 1)
        for box in boxes where !spansAGutter(box, boundaries: boundaries) {
            perColumn[columnIndex(box, boundaries: boundaries)].append(box)
        }
        guard perColumn.allSatisfy({ $0.count >= minLinesPerColumn }) else { return [] }
        for i in 0..<(perColumn.count - 1) where !overlapsVertically(perColumn[i], perColumn[i + 1]) {
            return []
        }

        return boundaries
    }
}
