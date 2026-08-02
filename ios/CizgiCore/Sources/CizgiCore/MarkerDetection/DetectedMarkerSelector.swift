import Foundation
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
#endif

/// Feeds on-device marker detection into the capture pipeline (§9, §25 Faz 2).
///
/// This is the seam `ManualSelectionOnly` was standing in for: with it
/// attached, a page whose underline is unambiguous goes straight through, and
/// only the genuinely uncertain ones reach the confirmation screen (§24.2).
///
/// It stays conservative on purpose. `selectedLineIds` takes auto-candidates
/// only, so a line the detector is unsure about produces no selection and the
/// user is asked — §19.3 forbids turning an undetected marker into a card.
public struct DetectedMarkerSelector: MarkerSelecting {
    private let detector: MarkerDetector
    private let loadImage: @Sendable (URL) -> CGImage?

    public init(
        detector: MarkerDetector,
        loadImage: @escaping @Sendable (URL) -> CGImage? = DetectedMarkerSelector.defaultImageLoader
    ) {
        self.detector = detector
        self.loadImage = loadImage
    }

    /// Convenience initializer using the bundled thresholds.
    public init() throws {
        self.init(detector: MarkerDetector(config: try MarkerConfig.bundled()))
    }

    public static let defaultImageLoader: @Sendable (URL) -> CGImage? = { url in
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
        #else
        return nil
        #endif
    }

    public func selectLines(in page: RecognizedPage, imageURL: URL) async throws -> [String] {
        guard
            let image = loadImage(imageURL),
            let buffer = try? PixelBuffer(cgImage: image)
        else {
            // Unreadable image: return nothing rather than throwing. The
            // pipeline reads "no selection" as "ask the user", which is the
            // right outcome — a detector that cannot see the page has no
            // opinion, and turning that into a job failure would lose a
            // capture over a decoding problem (§21.2).
            return []
        }

        let boxes = page.lines.map {
            LineBox($0, imageWidth: buffer.width, imageHeight: buffer.height)
        }
        // Page quality from the OCR's own confidence: a blurry page reads
        // poorly, and §9.3 wants that reflected in the selection score rather
        // than assumed away.
        let quality = page.lines.isEmpty
            ? 0.0
            : page.lines.map(\.confidence).reduce(0, +) / Double(page.lines.count)

        let detections = detector.analyze(page: buffer, lines: boxes, documentQuality: quality)
        let selected = Set(MarkerDetector.selectedLineIds(detections))

        // Returned in page order, not detection order, so the passage reads the
        // way it does on the page.
        return page.lines.map(\.id).filter(selected.contains)
    }
}
