import Foundation
import CizgiCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Fingerprints a captured page so the app can recognise one it has seen
/// before (ANA-PLAN §17, §21.1).
///
/// `CapturedPage.perceptualHash` has been in the model since Faz 1 with nothing
/// writing to it, so re-photographing a page — the obvious thing to do after a
/// blurry first shot — produced a second full set of cards and paid the provider
/// a second time for them.
///
/// The comparison itself lives in `PerceptualHasher` (CizgiCore), where it is
/// tested without an image decoder. This is only the part that needs an image:
/// getting grayscale samples out of the captured bytes.
enum PageImageHasher {
    /// Small on purpose. The hash reduces to 9×8 regardless, and decoding a
    /// full-resolution scan to throw away all but 72 averages would cost real
    /// time on every capture.
    static let sampleEdge = 64

    static func hash(_ data: Data) -> PerceptualHash? {
        #if canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: sampleEdge,
            // Without this a page photographed sideways hashes as a different
            // page from the same one held upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
            let buffer = try? PixelBuffer(cgImage: thumbnail)
        else { return nil }

        // `gray` is already a 0–255 mean of the three channels.
        var grayscale = [UInt8](repeating: 0, count: buffer.width * buffer.height)
        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                grayscale[y * buffer.width + x] = UInt8(min(255, max(0, buffer.gray(x: x, y: y))))
            }
        }
        return PerceptualHasher.hash(grayscale: grayscale, width: buffer.width, height: buffer.height)
        #else
        return nil
        #endif
    }
}
