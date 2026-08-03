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

    /// Returns `boxes`' indices in reading order.
    static func order(_ boxes: [Box]) -> [Int] {
        func band(_ box: Box) -> Int { Int((box.minY / bandHeight).rounded()) }
        func withinColumn(_ lhs: Int, _ rhs: Int) -> Bool {
            let a = boxes[lhs], b = boxes[rhs]
            let bandA = band(a), bandB = band(b)
            if bandA != bandB { return bandA < bandB }
            return a.minX < b.minX
        }

        let indices = Array(boxes.indices)
        let boundaries = columnBoundaries(for: boxes)
        guard !boundaries.isEmpty else {
            return indices.sorted(by: withinColumn)
        }

        func columnIndex(_ box: Box) -> Int {
            let center = (box.minX + box.maxX) / 2
            return boundaries.filter { $0 < center }.count
        }

        var byColumn = [[Int]](repeating: [], count: boundaries.count + 1)
        for index in indices {
            byColumn[columnIndex(boxes[index])].append(index)
        }
        return byColumn.flatMap { $0.sorted(by: withinColumn) }
    }

    /// Finds x-positions of vertical whitespace gutters wide and central
    /// enough to be column breaks rather than ordinary margins.
    ///
    /// A handful of full-width outliers (a header, a page number) are
    /// tolerated — `crossingTolerance` — rather than blocking detection
    /// outright.
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

        var perColumn = [Int](repeating: 0, count: boundaries.count + 1)
        for box in boxes {
            let center = (box.minX + box.maxX) / 2
            perColumn[boundaries.filter { $0 < center }.count] += 1
        }
        guard perColumn.allSatisfy({ $0 >= minLinesPerColumn }) else { return [] }

        return boundaries
    }
}
