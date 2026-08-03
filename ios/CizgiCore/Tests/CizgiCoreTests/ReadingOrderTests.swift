import XCTest
@testable import CizgiCore

final class ReadingOrderTests: XCTestCase {
    private func box(x: Double, y: Double, width: Double, height: Double = 0.03) -> ReadingOrder.Box {
        ReadingOrder.Box(minX: x, minY: y, maxX: x + width, maxY: y + height)
    }

    // MARK: - columnBoundaries

    func testFindsNothingWithTooFewItemsToInferALayout() {
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: [box(x: 0.1, y: 0.1, width: 0.2)]), [])
    }

    func testFindsNothingForAnOrdinarySingleColumnPage() {
        let boxes = (0..<8).map { box(x: 0.1, y: Double($0) * 0.05, width: 0.8) }
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: boxes), [])
    }

    func testFindsTheGutterOfAGenuineTwoColumnLayout() {
        let boxes = [0.1, 0.2, 0.3, 0.4].flatMap { y in
            [box(x: 0.05, y: y, width: 0.4), box(x: 0.55, y: y, width: 0.4)]
        }
        let boundaries = ReadingOrder.columnBoundaries(for: boxes)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0], 0.5, accuracy: 0.05)
    }

    func testDoesNotLetAShortRightColumnsTrailingMarginMasqueradeAsASecondGutter() {
        // The right column ends at x=0.84 (a short comparison-list entry), so
        // its trailing margin to the page edge is 16% wide — wide enough to
        // pass the gutter-width check, with a center right at the old edge
        // threshold. Without rejecting edge-touching runs outright, this
        // reads as a second "gutter", produces an empty third column, fails
        // the minimum-lines check, and the whole two-column split is
        // discarded — leaving the page interleaved row by row again.
        let boxes = [0.1, 0.2, 0.3].flatMap { y in
            [box(x: 0.05, y: y, width: 0.4), box(x: 0.5, y: y, width: 0.34)]
        }
        let boundaries = ReadingOrder.columnBoundaries(for: boxes)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0], 0.45, accuracy: 0.05)
    }

    func testIgnoresANarrowNearEdgeGapAsAnOrdinaryMargin() {
        // Content spans [0.05, 0.97] almost fully; the only "gaps" are the
        // page margins on either side, which must not read as a column split.
        let boxes = (0..<8).map { box(x: 0.05, y: Double($0) * 0.05, width: 0.92) }
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: boxes), [])
    }

    func testToleratesOneFullWidthOutlierCrossingTheGutter() {
        let columns = [0.2, 0.3, 0.4, 0.5, 0.6].flatMap { y in
            [box(x: 0.05, y: y, width: 0.4), box(x: 0.55, y: y, width: 0.4)]
        }
        let header = box(x: 0.05, y: 0.05, width: 0.9)
        let boundaries = ReadingOrder.columnBoundaries(for: [header] + columns)
        XCTAssertEqual(boundaries.count, 1)
        XCTAssertEqual(boundaries[0], 0.5, accuracy: 0.05)
    }

    func testRejectsAGapThatWouldLeaveAColumnWithTooFewLines() {
        // One short, indented line creates a thin apparent gap, but nothing
        // else on the page is split that way — must not read as two columns.
        var boxes = [box(x: 0.3, y: 0.1, width: 0.3)]
        boxes += (0..<6).map { box(x: 0.05, y: 0.2 + Double($0) * 0.05, width: 0.9) }
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: boxes), [])
    }

    func testRejectsHorizontallySeparatedRegionsThatNeverCoexistVertically() {
        // Two right-aligned metadata lines at the very top, then unrelated
        // left-aligned body text below: different x-ranges, but not a column
        // layout — one region sits entirely above the other.
        let metadata = [0.02, 0.05].map { box(x: 0.6, y: $0, width: 0.35, height: 0.02) }
        let body = (0..<6).map { box(x: 0.05, y: 0.15 + Double($0) * 0.05, width: 0.5) }
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: metadata + body), [])
    }

    func testRejectsColumnsWhoseOuterEnvelopesOverlapButWhoseLinesNeverActuallyCoexist() {
        // Left column has two lines far apart (top and bottom of the page)
        // with a large empty gap between them; the right column's lines sit
        // entirely in that gap. The left column's *envelope* [0.05, 0.88]
        // contains the right column's range, but no line from either side is
        // ever actually beside a line from the other.
        let left = [0.05, 0.85].map { box(x: 0.05, y: $0, width: 0.4) }
        let right = [0.4, 0.42].map { box(x: 0.55, y: $0, width: 0.4) }
        XCTAssertEqual(ReadingOrder.columnBoundaries(for: left + right), [])
    }

    // MARK: - order

    func testFallsBackToTopToBottomThenLeftToRightWithNoDetectedColumns() {
        let boxes = [
            box(x: 0.1, y: 0.5, width: 0.5),   // "alt"
            box(x: 0.6, y: 0.1, width: 0.5),   // "üst sağ"
            box(x: 0.1, y: 0.1, width: 0.5),   // "üst sol"
        ]
        XCTAssertEqual(ReadingOrder.order(boxes), [2, 1, 0])
    }

    func testReadsATwoColumnComparisonListColumnByColumnNotRowByRow() {
        // Mirrors the real bug: a Nekroz/Apoptoz style comparison list where
        // each row has one bullet per column at the same height. Row-by-row
        // reading interleaves the two topics into one garbled sentence.
        let nekroz = [0.1, 0.2, 0.3].map { box(x: 0.05, y: $0, width: 0.4) }
        let apoptoz = [0.1, 0.2, 0.3].map { box(x: 0.55, y: $0, width: 0.4) }
        // Interleaved input order, as a naive row-by-row OCR pass would emit it.
        let boxes = [nekroz[0], apoptoz[0], nekroz[1], apoptoz[1], nekroz[2], apoptoz[2]]

        // Indices 0, 2, 4 are Nekroz; 1, 3, 5 are Apoptoz — column order means
        // all of Nekroz (top to bottom) before any of Apoptoz.
        XCTAssertEqual(ReadingOrder.order(boxes), [0, 2, 4, 1, 3, 5])
    }

    func testPlacesAHeaderBeforeBothColumnsRatherThanInsideOneOfThem() {
        let header = box(x: 0.05, y: 0.02, width: 0.9)   // index 0
        let nekroz = [0.1, 0.2, 0.3].map { box(x: 0.05, y: $0, width: 0.4) }   // indices 1, 2, 3
        let apoptoz = [0.1, 0.2, 0.3].map { box(x: 0.55, y: $0, width: 0.4) }  // indices 4, 5, 6
        let boxes = [header] + nekroz + apoptoz

        XCTAssertEqual(ReadingOrder.order(boxes), [0, 1, 2, 3, 4, 5, 6])
    }

    func testPlacesAFooterAfterBothColumnsRatherThanBetweenThem() {
        // The exact corruption a center-only assignment would cause: a footer
        // stranded between the two columns it actually follows.
        let nekroz = [0.1, 0.2, 0.3].map { box(x: 0.05, y: $0, width: 0.4) }   // indices 0, 1, 2
        let apoptoz = [0.1, 0.2, 0.3].map { box(x: 0.55, y: $0, width: 0.4) }  // indices 3, 4, 5
        let footer = box(x: 0.05, y: 0.4, width: 0.9)                          // index 6
        let boxes = nekroz + apoptoz + [footer]

        XCTAssertEqual(ReadingOrder.order(boxes), [0, 1, 2, 3, 4, 5, 6])
    }
}
