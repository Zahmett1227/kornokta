import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Cutting an open-book capture down to the page the user actually framed.
///
/// Two independent things conspire to put the neighbouring page into a shot the
/// user carefully centred on one page:
///
/// 1. `VNDocumentCameraViewController` shows its preview full-screen while it
///    captures the sensor's own 4:3 frame. Scaled to fill a portrait iPhone's
///    much taller, narrower window, the left and right edges of what is
///    captured are never on screen. Framing more carefully cannot help — the
///    user is aiming at a viewfinder that is not showing them the whole frame.
/// 2. The scanner's edge detection reads an open book as a single document: the
///    gutter is not a straight, contrasting border, so the quad it locks onto
///    is the outside of the spread, which it then deskews into one rectangle.
///
/// The second one is what makes this cheap to fix. A spread comes back already
/// perspective-corrected, so the gutter lands near the horizontal middle and a
/// straight vertical cut is enough — no quad, no corner dragging.
///
/// Cropping *before* the page is stored, rather than hinting the model to
/// ignore half the image, is deliberate. The upload budget
/// (`UploadImageEncoder.defaultMaxPixelSize`) is spent on the whole image, so a
/// spread halves the resolution of the page that mattered, and pays the
/// provider to read a page nobody asked about.
public enum PageSplit {

    // MARK: The decision

    /// Width ÷ height above which a capture is treated as a spread.
    ///
    /// A single book page is portrait (roughly 0.65–0.8); a deskewed spread is
    /// landscape (roughly 1.2–1.6). The gap is wide, so the threshold sits just
    /// past square: a false positive costs one extra tap on "Tümü", a false
    /// negative is the bug this type exists for.
    public static let spreadAspectThreshold = 1.05

    /// Where the cut goes when nothing has been dragged. The scanner deskews
    /// the spread, so the gutter is close to the middle before any adjustment.
    public static let defaultSplitRatio = 0.5

    /// How far the cut may be dragged. Bounded rather than free because a cut
    /// at the very edge produces a sliver with no text on it, which reads as
    /// "the app dropped my page" once the cards come back empty.
    public static let minSplitRatio = 0.15
    public static let maxSplitRatio = 0.85

    /// Which part of the capture is kept.
    public enum Selection: String, Sendable, Equatable, CaseIterable {
        case left
        case right
        /// Keep the image as it is — the escape hatch for a spread that really
        /// is one unit (a table running across both pages), and for a false
        /// positive from `isLikelySpread`.
        case whole
    }

    /// A crop in image pixels, origin at the top-left — the same convention
    /// `CGImage.cropping(to:)` uses, so nothing has to flip anything.
    public struct PixelRect: Sendable, Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int

        public init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// EXIF orientations 5–8 are the quarter-turns: the stored buffer is
    /// sideways relative to how the photo is meant to be seen, so its width and
    /// height mean the opposite of what the aspect test wants.
    ///
    /// In practice every image reaching this point is already upright — the
    /// document camera writes no orientation flag and `ImportedImage.normalize`
    /// bakes the gallery's flag into the pixels — but "in practice upright" is
    /// exactly the assumption that turns into a wrong crop the day an import
    /// path changes.
    public static func orientationSwapsAxes(_ orientation: Int) -> Bool {
        (5...8).contains(orientation)
    }

    /// Does this look like a photograph of an open book rather than one page?
    public static func isLikelySpread(
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int = ImportedImage.uprightOrientation
    ) -> Bool {
        let width = orientationSwapsAxes(orientation) ? pixelHeight : pixelWidth
        let height = orientationSwapsAxes(orientation) ? pixelWidth : pixelHeight
        guard width > 0, height > 0 else { return false }
        return Double(width) / Double(height) > spreadAspectThreshold
    }

    /// Keeps a dragged cut inside the bounds above.
    ///
    /// Public because the drag gesture has to obey the same rule the crop does:
    /// if the UI let the line travel further than the crop accepts, the line
    /// and the resulting page would disagree, and the user would trust the line.
    public static func clampedSplitRatio(_ ratio: Double) -> Double {
        guard ratio.isFinite else { return defaultSplitRatio }
        return min(max(ratio, minSplitRatio), maxSplitRatio)
    }

    /// The pixels to keep, or `nil` when there is nothing to do.
    ///
    /// Pure and separate from the encoder on purpose: which pixels survive a
    /// capture is a decision, and decisions in this project are testable
    /// without an image decoder.
    public static func cropRect(
        pixelWidth: Int,
        pixelHeight: Int,
        selection: Selection,
        splitRatio: Double = defaultSplitRatio
    ) -> PixelRect? {
        guard selection != .whole else { return nil }
        // Two columns cannot be cut out of a one-pixel-wide image, and a zero
        // dimension is not an image at all.
        guard pixelWidth > 1, pixelHeight > 0 else { return nil }

        let ratio = clampedSplitRatio(splitRatio)
        // Clamped after rounding as well: `minSplitRatio` keeps the cut away
        // from the edge in ratio terms, but a narrow image can still round both
        // sides to nothing, and an empty crop must never reach `cropping(to:)`.
        let cut = min(max(Int((Double(pixelWidth) * ratio).rounded()), 1), pixelWidth - 1)

        switch selection {
        case .left:
            return PixelRect(x: 0, y: 0, width: cut, height: pixelHeight)
        case .right:
            return PixelRect(x: cut, y: 0, width: pixelWidth - cut, height: pixelHeight)
        case .whole:
            return nil
        }
    }

    // MARK: Applying it

    #if canImport(ImageIO)
    public enum CropError: Error, Equatable {
        /// Not an image, or one no decoder on the device accepts.
        case unreadable
        /// Decodable, but the crop or the re-encode failed.
        case couldNotConvert
    }

    /// Reads only the header, so this is cheap enough to run on every captured
    /// page before anything is written to disk.
    public static func isLikelySpread(_ data: Data) -> Bool {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let size = UploadImageEncoder.pixelSize(of: source)
        else { return false }
        return isLikelySpread(
            pixelWidth: size.width,
            pixelHeight: size.height,
            orientation: ImportedImage.exifOrientation(of: source)
        )
    }

    /// Returns the chosen half as fresh JPEG bytes.
    ///
    /// Encoded at `ImportedImage.quality`, the same setting the document
    /// scanner and the gallery import use, so a cropped page is not visibly
    /// softer than one that skipped this step.
    public static func crop(
        _ data: Data,
        selection: Selection,
        splitRatio: Double = defaultSplitRatio
    ) throws -> Data {
        guard selection != .whole else { return data }

        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let size = UploadImageEncoder.pixelSize(of: source)
        else { throw CropError.unreadable }

        // Orientation is baked into the pixels first, exactly as
        // `ImportedImage.normalize` does it: `CGImage.cropping(to:)` knows
        // nothing about EXIF, so cropping a rotated photo's raw buffer would
        // take the slice from the wrong edge. Passing the longest edge as the
        // limit means "full size, just upright" — nothing is downsampled here,
        // because the upload encoder has its own, smaller budget and applying
        // both would cost detail twice.
        guard
            let upright = UploadImageEncoder.thumbnail(
                from: source,
                maxPixelSize: max(size.width, size.height)
            )
        else { throw CropError.couldNotConvert }

        guard
            let rect = cropRect(
                pixelWidth: upright.width,
                pixelHeight: upright.height,
                selection: selection,
                splitRatio: splitRatio
            ),
            let cropped = upright.cropping(
                to: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            ),
            let encoded = UploadImageEncoder.jpeg(from: cropped, quality: ImportedImage.quality)
        else { throw CropError.couldNotConvert }

        return encoded
    }
    #endif
}
