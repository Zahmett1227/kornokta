import Foundation
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

/// What kind of image a blob of bytes actually is (ANA-PLAN §8.1).
///
/// Read from the bytes themselves rather than a file name, because the two
/// disagree on exactly the path this type exists for: `ImageStore` names every
/// page `…jpg` and `CapturePipeline.mimeType(for:)` derives the MIME from that
/// name, so a HEIC picked out of the photo library would travel to the provider
/// labelled `image/jpeg`. Small ones would even survive `UploadImageEncoder`
/// untouched (its "already small enough" branch deliberately avoids re-encoding
/// a JPEG) and fail at the provider, which accepts no HEIC — while large ones
/// happened to work, because they were re-encoded on the way out. "Works for
/// big photos, fails for small ones" is the worst kind of bug to ship.
public enum ImageFormat: String, Sendable, Equatable, CaseIterable {
    case jpeg
    case png
    case heic
    case gif
    case tiff
    case webp
    case unknown

    public var mimeType: String {
        switch self {
        case .jpeg: return "image/jpeg"
        case .png: return "image/png"
        case .heic: return "image/heic"
        case .gif: return "image/gif"
        case .tiff: return "image/tiff"
        case .webp: return "image/webp"
        case .unknown: return "application/octet-stream"
        }
    }

    /// Formats the card provider accepts. HEIC is the one the photo library
    /// hands back by default and the one nothing downstream can use.
    public var isProviderSupported: Bool {
        switch self {
        case .jpeg, .png, .gif, .webp: return true
        case .heic, .tiff, .unknown: return false
        }
    }

    /// Magic-byte sniffing. Deliberately Foundation-only: which formats need
    /// converting is a decision, and decisions in this project are testable
    /// without an image decoder.
    public static func detect(_ data: Data) -> ImageFormat {
        func matches(_ bytes: [UInt8], at offset: Int) -> Bool {
            guard data.count >= offset + bytes.count else { return false }
            let start = data.index(data.startIndex, offsetBy: offset)
            for (index, byte) in bytes.enumerated() where data[data.index(start, offsetBy: index)] != byte {
                return false
            }
            return true
        }

        if matches([0xFF, 0xD8, 0xFF], at: 0) { return .jpeg }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], at: 0) { return .png }
        if matches([0x47, 0x49, 0x46, 0x38], at: 0) { return .gif }
        // RIFF????WEBP
        if matches([0x52, 0x49, 0x46, 0x46], at: 0), matches([0x57, 0x45, 0x42, 0x50], at: 8) { return .webp }
        if matches([0x49, 0x49, 0x2A, 0x00], at: 0) || matches([0x4D, 0x4D, 0x00, 0x2A], at: 0) { return .tiff }
        // ISO base media: "ftyp" at byte 4, then a brand. The brands below are
        // what an iPhone writes for a photo and for a Live Photo's still.
        if matches([0x66, 0x74, 0x79, 0x70], at: 4) {
            for brand in ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"] {
                if matches(Array(brand.utf8), at: 8) { return .heic }
            }
        }
        return .unknown
    }
}

/// Why an imported photo has to be re-encoded before it enters the queue.
///
/// Kept as an explicit reason rather than a bare `Bool` so the decision can be
/// asserted in tests one cause at a time — and so a future "why did this photo
/// get re-encoded?" question has an answer.
public enum ImportNormalizationReason: String, Sendable, Equatable {
    /// Not something the provider can read (HEIC, above all).
    case unsupportedFormat
    /// A gallery photo carries its rotation in an EXIF flag; the document
    /// camera's output does not. If the flag is not baked into the pixels the
    /// vision model reads the page sideways — and says nothing about it.
    case orientation
    case tooManyPixels
    case tooManyBytes
}

public struct ImportDecision: Sendable, Equatable {
    public let reasons: [ImportNormalizationReason]
    public var needsNormalization: Bool { !reasons.isEmpty }

    public init(reasons: [ImportNormalizationReason]) {
        self.reasons = reasons
    }
}

public enum ImportedImage {
    /// Longest edge kept for the *stored* page.
    ///
    /// Matches what `VNDocumentCameraViewController` hands back on a current
    /// iPhone (~3000 px on the long edge), so an imported page and a captured
    /// one look the same to everything downstream — including the upload path,
    /// which downsizes to its own 2600 px budget separately.
    public static let maxPixelSize = 3000
    /// The document scanner writes its pages at 0.9; matching it keeps a
    /// re-encoded import from being visibly softer than a capture.
    public static let quality = 0.9
    /// Above this an import is re-encoded even if nothing else asks for it:
    /// a 12 MP HEIC becomes a much larger JPEG, and the stored page is kept
    /// for as long as the user keeps the card.
    public static let maxBytes = 6_000_000

    /// EXIF orientation 1 means "the pixels are already upright".
    public static let uprightOrientation = 1

    /// Pure decision: given what the bytes are, must they be re-encoded?
    ///
    /// A plain, upright, reasonably sized JPEG passes through untouched — a
    /// JPEG loses a little every time it is decoded and re-encoded, and here
    /// that loss would buy nothing.
    public static func decision(
        format: ImageFormat,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        orientation: Int
    ) -> ImportDecision {
        var reasons: [ImportNormalizationReason] = []
        if format != .jpeg { reasons.append(.unsupportedFormat) }
        if orientation != uprightOrientation { reasons.append(.orientation) }
        if max(pixelWidth, pixelHeight) > maxPixelSize { reasons.append(.tooManyPixels) }
        if byteCount > maxBytes { reasons.append(.tooManyBytes) }
        return ImportDecision(reasons: reasons)
    }

    /// What the import produced, and whether the bytes changed.
    public struct Normalized: Sendable, Equatable {
        public let data: Data
        public let format: ImageFormat
        public let wasReencoded: Bool

        public init(data: Data, format: ImageFormat, wasReencoded: Bool) {
            self.data = data
            self.format = format
            self.wasReencoded = wasReencoded
        }
    }

    public enum ImportError: Error, Equatable {
        /// Not an image at all, or an image nothing on the device can decode.
        case unreadable
        /// Decodable, but re-encoding failed — so the bytes cannot be made
        /// safe to send and must not be queued pretending they are.
        case couldNotConvert
    }

    /// Brings a photo picked from the library onto the same footing as a camera
    /// capture: JPEG, orientation baked into the pixels, sane size.
    ///
    /// One conversion point, on purpose. The alternative — carrying the real
    /// format through storage, the perceptual hash, the upload encoder and the
    /// backup — would put format branching in five places to save one
    /// re-encode on an already-perfect photo.
    ///
    /// Throws rather than falling back to the original bytes: unlike
    /// `UploadImageEncoder`, which may safely send what it was given, an
    /// unconvertible import is precisely the case this function exists to stop.
    public static func normalize(_ data: Data) throws -> Normalized {
        let format = ImageFormat.detect(data)

        #if canImport(ImageIO)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let dimensions = UploadImageEncoder.pixelSize(of: source)
        else { throw ImportError.unreadable }

        let verdict = Self.decision(
            format: format,
            byteCount: data.count,
            pixelWidth: dimensions.width,
            pixelHeight: dimensions.height,
            orientation: exifOrientation(of: source)
        )
        guard verdict.needsNormalization else {
            return Normalized(data: data, format: .jpeg, wasReencoded: false)
        }

        // `thumbnail(from:maxPixelSize:)` sets kCGImageSourceCreateThumbnailWithTransform,
        // which is what applies the EXIF rotation to the pixels.
        let targetEdge = min(max(dimensions.width, dimensions.height), maxPixelSize)
        guard
            let image = UploadImageEncoder.thumbnail(from: source, maxPixelSize: targetEdge),
            let encoded = UploadImageEncoder.jpeg(from: image, quality: quality)
        else { throw ImportError.couldNotConvert }

        return Normalized(data: encoded, format: .jpeg, wasReencoded: true)
        #else
        // No decoder on this platform. A JPEG is already what the pipeline
        // wants; anything else cannot be made into one here.
        guard format == .jpeg else { throw ImportError.couldNotConvert }
        return Normalized(data: data, format: .jpeg, wasReencoded: false)
        #endif
    }

    #if canImport(ImageIO)
    /// EXIF orientation, defaulting to upright when the file does not say.
    static func exifOrientation(of source: CGImageSource) -> Int {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let value = properties[kCGImagePropertyOrientation] as? Int
        else { return uprightOrientation }
        return value
    }
    #endif
}
