import Foundation
import CoreGraphics

/// A page image as plain RGBA bytes.
///
/// The detector needs per-pixel access, and `CGImage` does not give it: the
/// bytes may be planar, premultiplied, 16-bit, or in a colour space that makes
/// "red" mean something else. Redrawing into one known format once removes all
/// of that from the detection code, which then only has to be right about the
/// algorithm.
public struct PixelBuffer: Sendable {
    public let width: Int
    public let height: Int
    /// RGBA, 8 bits per component, row-major, no padding.
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public enum LoadError: Error, Sendable {
        case emptyImage
        case contextUnavailable
    }

    /// A named, fixed colour space, deliberately not
    /// `CGColorSpaceCreateDeviceRGB()` (see `init(cgImage:)`). Force-unwrapped
    /// because sRGB is one of the handful of spaces the system always
    /// provides by name; unlike a bundled resource, there is no real-world
    /// condition under which this is absent.
    static let pixelColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw LoadError.emptyImage }

        let count = width * height * 4
        // Allocated explicitly rather than handed an Array's buffer.
        // `withUnsafeMutableBytes` only guarantees its pointer for the
        // duration of the closure, so a CGContext built inside one and drawn
        // into afterwards writes through a pointer that is no longer
        // guaranteed to address that array — and copy-on-write could have
        // moved the storage in between.
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: count)

        // Explicit sRGB, not `CGColorSpaceCreateDeviceRGB()`: "device" RGB is
        // not a fixed space, it means "whatever this display's current
        // profile is", which is the opposite of the reproducibility §9.3
        // needs — a threshold in the shared config
        // (`highlight.colorHueRangesHSV`) would then only be valid on the
        // screen the calibration happened to run on.
        guard let context = CGContext(
            data: storage,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: Self.pixelColorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw LoadError.contextUnavailable }

        // White first: a source with transparency would otherwise composite
        // onto black, and a page that reads as black everywhere looks like
        // solid ink to the underline detector. `CGColor.sRGB` rather than
        // `setFillColor(gray:alpha:)` — see its doc comment.
        context.setFillColor(CGColor.sRGB(1, 1, 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        self.width = width
        self.height = height
        self.pixels = [UInt8](UnsafeBufferPointer(
            start: storage.assumingMemoryBound(to: UInt8.self),
            count: count
        ))
    }

    /// Red, green, blue at a pixel. Out-of-bounds reads return black rather
    /// than trapping: the detector clamps its own regions, and a crash on a
    /// stray coordinate would lose a capture over an off-by-one.
    @inline(__always)
    public func rgb(x: Int, y: Int) -> (r: Double, g: Double, b: Double) {
        guard x >= 0, y >= 0, x < width, y < height else { return (0, 0, 0) }
        let offset = (y * width + x) * 4
        return (Double(pixels[offset]), Double(pixels[offset + 1]), Double(pixels[offset + 2]))
    }

    /// Mean of the three channels, matching the reference implementation's
    /// grayscale (a plain average, not a luminance-weighted one).
    @inline(__always)
    public func gray(x: Int, y: Int) -> Double {
        let (r, g, b) = rgb(x: x, y: y)
        return (r + g + b) / 3.0
    }

    /// HSV on OpenCV's scale: H 0–179, S 0–255, V 0–255.
    ///
    /// The scale matters — the thresholds in the shared config are written for
    /// it, and using the more common 0–360 hue would silently move every hue
    /// range to the wrong colour.
    @inline(__always)
    public func hsv(x: Int, y: Int) -> (h: Double, s: Double, v: Double) {
        let (r, g, b) = rgb(x: x, y: y)
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        let delta = maximum - minimum

        var hue: Double = 0
        if delta > 0 {
            if maximum == r {
                hue = 60 * (((g - b) / delta).truncatingRemainder(dividingBy: 6))
            } else if maximum == g {
                hue = 60 * (((b - r) / delta) + 2)
            } else {
                hue = 60 * (((r - g) / delta) + 4)
            }
        }
        if hue < 0 { hue += 360 }

        let saturation = maximum > 0 ? (delta / maximum) * 255.0 : 0
        // OpenCV stores hue halved so it fits in a byte.
        return (hue / 2.0, saturation, maximum)
    }
}

extension CGColor {
    /// A colour explicitly tagged with `PixelBuffer.pixelColorSpace`, rather
    /// than the untagged convenience initializers (`CGColor(red:green:blue:alpha:)`,
    /// `setFillColor(gray:alpha:)`).
    ///
    /// Those construct the colour in an implicit "generic RGB" space that is
    /// not necessarily the space a context was created with — so filling with
    /// one forces a conversion on every fill, and that conversion is not the
    /// identity. Measured directly: bisecting a case where `PixelBuffer` read
    /// back a stray green channel showed the drift was already present in the
    /// *source* image, before `PixelBuffer` ever touched it — filling an
    /// explicitly-sRGB context with `CGColor(red: 1, green: 0, blue: 0, alpha:
    /// 1)` alone was enough to read back green at 38, not 0.
    static func sRGB(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: PixelBuffer.pixelColorSpace, components: [red, green, blue, alpha])!
    }

    static func sRGBGray(_ value: CGFloat, alpha: CGFloat = 1) -> CGColor {
        sRGB(value, value, value, alpha: alpha)
    }
}
