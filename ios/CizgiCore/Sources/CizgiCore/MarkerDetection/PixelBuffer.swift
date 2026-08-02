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

    public init(cgImage: CGImage) throws {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { throw LoadError.emptyImage }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        // premultipliedLast + sRGB: the same interpretation every time,
        // whatever the source image was.
        guard
            let context = bytes.withUnsafeMutableBytes({ raw -> CGContext? in
                CGContext(
                    data: raw.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            })
        else { throw LoadError.contextUnavailable }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.width = width
        self.height = height
        self.pixels = bytes
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

/// A rectangle clamped to the image.
///
/// Returns nil when the requested rectangle lies wholly outside it. Clamping
/// alone is not enough: a negative upper bound would be read as an offset from
/// the far edge and select a large unrelated region — a bug the reference
/// implementation hit and fixed.
public struct PixelRegion: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init?(x: Int, y: Int, width: Int, height: Int, in buffer: PixelBuffer) {
        let x0 = max(0, x)
        let y0 = max(0, y)
        let x1 = min(buffer.width, x + width)
        let y1 = min(buffer.height, y + height)
        guard x1 > x0, y1 > y0 else { return nil }
        self.x = x0
        self.y = y0
        self.width = x1 - x0
        self.height = y1 - y0
    }
}
