import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// Preparing a captured page for upload (ANA-PLAN §7.2, §24.1).
///
/// `VNDocumentCameraViewController` hands back a full-resolution scan — on a
/// current iPhone roughly 3000×4000 — and at quality 0.9 that is 4–8 MB. Base64
/// adds a third on top. A serverless host caps the request body well below
/// that (Vercel's limit is 4.5 MB), so an untouched capture is rejected by the
/// platform *before* it reaches our handler: the phone gets an opaque failure
/// instead of the message the endpoint would have given it.
///
/// So the uploaded copy is downscaled. The **stored** page is untouched — §5.5's
/// "Kaynağı Göster" and §16 both want the original — this only changes what
/// travels.
///
/// The size is a deliberate compromise, not an arbitrary number. A 15 cm book
/// page at 2600 px on the long edge is about 310 dpi, comfortably above the
/// 200 dpi Document AI asks for, and small print is exactly where the critical
/// tokens live (§10.5). Shrinking further would trade OCR accuracy for upload
/// speed, which is the wrong way round for this app.
public struct PreparedUpload: Sendable, Equatable {
    public let data: Data
    public let mimeType: String
    /// False when the original was already small enough and was sent verbatim.
    public let wasResized: Bool

    public init(data: Data, mimeType: String, wasResized: Bool) {
        self.data = data
        self.mimeType = mimeType
        self.wasResized = wasResized
    }
}

public enum UploadImageEncoder {
    /// Longest edge of the uploaded copy, in pixels.
    public static let defaultMaxPixelSize = 2600
    public static let defaultQuality = 0.85
    /// Budget for the encoded bytes, chosen to stay under a 4.5 MB body limit
    /// after base64 inflates it by a third (3.2 MB × 1.34 ≈ 4.3 MB).
    public static let defaultMaxBytes = 3_200_000
    /// Second attempt when the first is still over budget. Lower quality is
    /// preferred to a smaller image: JPEG artefacts cost less OCR accuracy than
    /// missing pixels do.
    static let fallbackQuality = 0.6

    /// Reads the capture and returns what should be sent.
    ///
    /// Never throws on an image it cannot process — it returns the original
    /// bytes instead. A capture must not be lost because a decoder was unhappy
    /// (§21.2); the backend enforces its own ceiling and answers with a message
    /// the user can act on.
    public static func prepare(
        contentsOf url: URL,
        mimeType: String,
        maxPixelSize: Int = defaultMaxPixelSize,
        quality: Double = defaultQuality,
        maxBytes: Int = defaultMaxBytes
    ) throws -> PreparedUpload {
        let original = try Data(contentsOf: url)
        return prepare(
            original: original,
            mimeType: mimeType,
            maxPixelSize: maxPixelSize,
            quality: quality,
            maxBytes: maxBytes
        )
    }

    static func prepare(
        original: Data,
        mimeType: String,
        maxPixelSize: Int = defaultMaxPixelSize,
        quality: Double = defaultQuality,
        maxBytes: Int = defaultMaxBytes
    ) -> PreparedUpload {
        let untouched = PreparedUpload(data: original, mimeType: mimeType, wasResized: false)

        // Only raster images are re-encoded. A PDF page is passed through: it
        // is already compact, and rasterizing it here would throw away the text
        // layer the OCR would rather have.
        guard mimeType.hasPrefix("image/") else { return untouched }

        #if canImport(ImageIO)
        guard
            let source = CGImageSourceCreateWithData(original as CFData, nil),
            let dimensions = pixelSize(of: source)
        else { return untouched }

        let longestEdge = max(dimensions.width, dimensions.height)
        // Already small enough: send the original rather than re-encoding it.
        // A JPEG decoded and re-encoded loses a little every time, and here it
        // would buy nothing.
        if longestEdge <= maxPixelSize && original.count <= maxBytes {
            return untouched
        }

        let targetEdge = min(longestEdge, maxPixelSize)
        guard let scaled = thumbnail(from: source, maxPixelSize: targetEdge) else {
            return untouched
        }

        guard let encoded = jpeg(from: scaled, quality: quality) else { return untouched }
        if encoded.count <= maxBytes {
            return PreparedUpload(data: encoded, mimeType: "image/jpeg", wasResized: true)
        }

        if let retried = jpeg(from: scaled, quality: fallbackQuality), retried.count < encoded.count {
            return PreparedUpload(data: retried, mimeType: "image/jpeg", wasResized: true)
        }
        // Still over budget: send it anyway. The server's 413 names the limit,
        // which is more useful than a silent local refusal.
        return PreparedUpload(data: encoded, mimeType: "image/jpeg", wasResized: true)
        #else
        return untouched
        #endif
    }

    #if canImport(ImageIO)
    /// Pixel dimensions without decoding the whole image.
    static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    static func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Applies the EXIF orientation to the pixels. Without it a photo
            // taken sideways would be uploaded sideways while the phone's own
            // reading is upright — the two line boxes would then never pair,
            // and every page would land on the confirmation screen.
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func jpeg(from image: CGImage, quality: Double) -> Data? {
        let output = NSMutableData()
        // "public.jpeg" rather than the deprecated kUTTypeJPEG constant, and
        // without pulling in UniformTypeIdentifiers for one string.
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, "public.jpeg" as CFString, 1, nil
            )
        else { return nil }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
    #endif
}
