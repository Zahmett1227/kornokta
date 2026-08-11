import XCTest
@testable import CizgiCore

/// The "which page did you mean?" decision (`PageSplit`).
///
/// Tested on numbers rather than on images: the two things that can go wrong
/// here — calling a single page a spread, and cutting the wrong column of
/// pixels — are both arithmetic, and both would reach the user as cards
/// generated from the page they did not photograph.
final class PageSplitDetectionTests: XCTestCase {
    /// A book page held upright. The overwhelmingly common case, and the one
    /// that must never interrupt the capture flow with a question.
    func testSinglePortraitPageIsNotASpread() {
        XCTAssertFalse(PageSplit.isLikelySpread(pixelWidth: 2000, pixelHeight: 2800))
        XCTAssertFalse(PageSplit.isLikelySpread(pixelWidth: 2100, pixelHeight: 2600))
    }

    /// An open book, deskewed by the document scanner: roughly twice as wide
    /// as one page, so clearly landscape.
    func testOpenBookIsASpread() {
        XCTAssertTrue(PageSplit.isLikelySpread(pixelWidth: 3000, pixelHeight: 2100))
        XCTAssertTrue(PageSplit.isLikelySpread(pixelWidth: 2800, pixelHeight: 2000))
    }

    /// The threshold sits just past square, and a square image is not a spread:
    /// asking is only justified once the shape actually says "two pages".
    func testSquareIsNotASpread() {
        XCTAssertFalse(PageSplit.isLikelySpread(pixelWidth: 2000, pixelHeight: 2000))
    }

    func testDegenerateSizesAreNotSpreads() {
        XCTAssertFalse(PageSplit.isLikelySpread(pixelWidth: 0, pixelHeight: 2000))
        XCTAssertFalse(PageSplit.isLikelySpread(pixelWidth: 2000, pixelHeight: 0))
    }

    /// A quarter-turn in the EXIF flag means the stored buffer is sideways: a
    /// portrait page is filed as a landscape one. Reading the raw dimensions
    /// would then send every single page to the crop step.
    func testRotatedOrientationSwapsTheAxes() {
        // Stored landscape, displayed portrait — a single page.
        XCTAssertFalse(
            PageSplit.isLikelySpread(pixelWidth: 2800, pixelHeight: 2000, orientation: 6)
        )
        // Stored portrait, displayed landscape — a spread.
        XCTAssertTrue(
            PageSplit.isLikelySpread(pixelWidth: 2000, pixelHeight: 2800, orientation: 8)
        )
    }

    /// Orientations 1–4 are the flips and the 180° turn; none of them exchange
    /// width and height.
    func testUprightAndFlippedOrientationsDoNotSwap() {
        for orientation in 1...4 {
            XCTAssertFalse(PageSplit.orientationSwapsAxes(orientation), "EXIF \(orientation)")
        }
        for orientation in 5...8 {
            XCTAssertTrue(PageSplit.orientationSwapsAxes(orientation), "EXIF \(orientation)")
        }
    }
}

final class PageSplitCropRectTests: XCTestCase {
    func testWholeKeepsEverythingByAskingForNoCrop() {
        XCTAssertNil(
            PageSplit.cropRect(pixelWidth: 3000, pixelHeight: 2000, selection: .whole)
        )
    }

    /// The two halves must tile the image exactly: no gap (a lost column of
    /// text at the gutter) and no overlap (the same sentence on two pages).
    func testHalvesTileTheImageExactly() {
        let width = 3001
        guard
            let left = PageSplit.cropRect(pixelWidth: width, pixelHeight: 2000, selection: .left),
            let right = PageSplit.cropRect(pixelWidth: width, pixelHeight: 2000, selection: .right)
        else { return XCTFail("both halves should exist") }

        XCTAssertEqual(left.x, 0)
        XCTAssertEqual(right.x, left.width)
        XCTAssertEqual(left.width + right.width, width)
        XCTAssertEqual(left.height, 2000)
        XCTAssertEqual(right.height, 2000)
    }

    func testSplitRatioMovesTheCut() {
        let left = PageSplit.cropRect(
            pixelWidth: 1000, pixelHeight: 800, selection: .left, splitRatio: 0.4
        )
        XCTAssertEqual(left?.width, 400)

        let right = PageSplit.cropRect(
            pixelWidth: 1000, pixelHeight: 800, selection: .right, splitRatio: 0.4
        )
        XCTAssertEqual(right?.x, 400)
        XCTAssertEqual(right?.width, 600)
    }

    /// A drag that runs off the edge is pulled back to the bounds rather than
    /// producing a sliver with no text on it.
    func testRatioIsClampedToTheBounds() {
        XCTAssertEqual(PageSplit.clampedSplitRatio(-4), PageSplit.minSplitRatio)
        XCTAssertEqual(PageSplit.clampedSplitRatio(9), PageSplit.maxSplitRatio)
        XCTAssertEqual(PageSplit.clampedSplitRatio(0.5), 0.5)

        let left = PageSplit.cropRect(
            pixelWidth: 1000, pixelHeight: 800, selection: .left, splitRatio: -4
        )
        XCTAssertEqual(left?.width, Int((1000 * PageSplit.minSplitRatio).rounded()))
    }

    /// A NaN would otherwise survive the comparisons and reach `rounded()`,
    /// where converting it to `Int` is a crash rather than a wrong crop. An
    /// infinity is treated the same way — not clamped to the far edge, because
    /// a non-finite ratio carries no information about where the user pointed.
    func testNonFiniteRatioFallsBackToTheDefault() {
        XCTAssertEqual(PageSplit.clampedSplitRatio(.nan), PageSplit.defaultSplitRatio)
        XCTAssertEqual(PageSplit.clampedSplitRatio(.infinity), PageSplit.defaultSplitRatio)

        let rect = PageSplit.cropRect(
            pixelWidth: 1000, pixelHeight: 800, selection: .left, splitRatio: .nan
        )
        XCTAssertEqual(rect?.width, 500)
    }

    /// Neither half may come out empty, whatever the rounding did — an empty
    /// rect is rejected by `CGImage.cropping(to:)` and would lose the page.
    func testNeitherHalfIsEverEmpty() {
        for width in 2...40 {
            for ratio in [PageSplit.minSplitRatio, 0.5, PageSplit.maxSplitRatio] {
                guard
                    let left = PageSplit.cropRect(
                        pixelWidth: width, pixelHeight: 10, selection: .left, splitRatio: ratio
                    ),
                    let right = PageSplit.cropRect(
                        pixelWidth: width, pixelHeight: 10, selection: .right, splitRatio: ratio
                    )
                else { return XCTFail("width \(width) ratio \(ratio)") }

                XCTAssertGreaterThan(left.width, 0, "width \(width) ratio \(ratio)")
                XCTAssertGreaterThan(right.width, 0, "width \(width) ratio \(ratio)")
                XCTAssertEqual(left.width + right.width, width, "width \(width) ratio \(ratio)")
            }
        }
    }

    func testImagesTooNarrowToSplitAreLeftAlone() {
        XCTAssertNil(PageSplit.cropRect(pixelWidth: 1, pixelHeight: 10, selection: .left))
        XCTAssertNil(PageSplit.cropRect(pixelWidth: 0, pixelHeight: 10, selection: .right))
        XCTAssertNil(PageSplit.cropRect(pixelWidth: 100, pixelHeight: 0, selection: .left))
    }
}
