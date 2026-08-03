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
    /// Two candidate columns must have at least this fraction of each side's
    /// lines vertically near a line on the other side, or they are not side
    /// by side — they are two horizontally-separated but vertically-stacked
    /// regions (e.g. a right-aligned header above unrelated left-aligned body
    /// text), and reading them column by column would reorder the page
    /// instead of fixing it.
    static let minVerticalOverlap = 0.5
    /// How far apart two boxes' vertical extents may be and still count as
    /// "the same row" for `overlapsVertically` — roughly one line height, so
    /// two independently-typeset columns with staggered baselines (never
    /// pixel-aligned between columns in practice) still read as coexisting,
    /// while regions that are genuinely stacked with a real gap between them
    /// do not.
    static let maxBaselineStagger = 0.03
    /// A box wider than this fraction of the page cannot fit inside a single
    /// column next to another — it is a page-spanning element (a header,
    /// footer, or page number), not evidence of a column's own text. Excluded
    /// from the gap scan below so any number of them, however many, never
    /// hide a real gutter.
    static let maxColumnItemWidth = 0.5

    /// True if `box`'s span crosses one of `boundaries` rather than sitting
    /// entirely inside one column — a header or footer spanning the gutter.
    private static func spansAGutter(_ box: Box, boundaries: [Double]) -> Bool {
        boundaries.contains { boundary in box.minX < boundary && box.maxX > boundary }
    }

    private static func columnIndex(_ box: Box, boundaries: [Double]) -> Int {
        let center = (box.minX + box.maxX) / 2
        return boundaries.filter { $0 < center }.count
    }

    /// Whether `a` and `b` sit close enough vertically to count as the same
    /// row, within `maxBaselineStagger` of slack in either direction.
    private static func coexist(_ a: Box, _ b: Box) -> Bool {
        a.minY - maxBaselineStagger < b.maxY && b.minY - maxBaselineStagger < a.maxY
    }

    /// Whether two non-empty groups of boxes coexist over a meaningful shared
    /// vertical range, rather than one sitting entirely above the other.
    /// Measured per box — does *this* box have a neighbor on the other side
    /// nearby? — rather than by each group's overall envelope or
    /// occupied-band set, which would call two groups "overlapping" whenever
    /// one's total span happens to enclose the other's, even with a real gap
    /// between them and no box ever actually beside another; or would reject
    /// two ordinary columns whenever their (never pixel-aligned) baselines
    /// happen to land in different bands.
    private static func overlapsVertically(_ a: [Box], _ b: [Box]) -> Bool {
        let aMatched = a.filter { box in b.contains { coexist(box, $0) } }.count
        let bMatched = b.filter { box in a.contains { coexist(box, $0) } }.count
        return Double(aMatched) / Double(a.count) >= minVerticalOverlap
            && Double(bMatched) / Double(b.count) >= minVerticalOverlap
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
    /// Page-spanning elements (a header, footer, page number — anything wider
    /// than `maxColumnItemWidth`) are excluded up front rather than merely
    /// tolerated: a page can have any number of them (a title *and* a footer)
    /// without hiding the real gutter between them.
    static func columnBoundaries(for boxes: [Box]) -> [Double] {
        guard boxes.count >= 2 * minLinesPerColumn else { return [] }

        let columnScoped = boxes.filter { $0.maxX - $0.minX <= maxColumnItemWidth }

        var coverage = [Int](repeating: 0, count: columnBuckets)
        for box in columnScoped {
            let start = max(0, Int((box.minX * Double(columnBuckets)).rounded(.down)))
            let end = min(columnBuckets, Int((box.maxX * Double(columnBuckets)).rounded(.up)))
            guard start < end else { continue }
            for bucket in start..<end { coverage[bucket] += 1 }
        }

        var boundaries: [Double] = []
        var index = 0
        while index < columnBuckets {
            guard coverage[index] == 0 else { index += 1; continue }
            let start = index
            while index < columnBuckets, coverage[index] == 0 { index += 1 }
            // A run reaching all the way to either edge is the page's own
            // outer margin, however wide — not a gap *between* two columns of
            // text, which has content on both sides by definition. The center
            // check alone can miss this: a wide trailing margin (e.g. a short
            // right column ending at x=0.84) can have its center fall outside
            // `columnEdgeMargin` even though it never separates two things.
            let touchesEdge = start == 0 || index == columnBuckets
            let width = Double(index - start) / Double(columnBuckets)
            let center = (Double(start) + Double(index)) / 2 / Double(columnBuckets)
            if !touchesEdge, width >= minGutterWidth, center >= columnEdgeMargin, center <= 1 - columnEdgeMargin {
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
