import Foundation
#if canImport(ImageIO)
import ImageIO
#endif

/// Whether bytes that claim to be a JPEG are one a viewer can actually show
/// whole (backup version 9, docs/ADR-011).
///
/// Two checks, because each misses what the other catches:
///
/// - **The marker walk** follows the segment structure from start-of-image to
///   end-of-image. It is the only check here that sees *truncation* — the
///   likeliest failure of a base64 field written by a generator that hit an
///   output limit. ImageIO does not: measured on a 900×1200 page cut in half,
///   `CGImageSourceGetStatus` still reports complete and the image still
///   "opens", then draws with its lower half missing.
/// - **ImageIO** has to recognise the header as a JPEG and read pixel
///   dimensions from it. That catches a header damaged in ways the walk
///   tolerates (segment lengths that happen to line up over garbage).
///
/// Neither is a full decode: bytes zeroed in the middle of the scan data are
/// structurally valid and render with artefacts, not blank. Decoding every
/// page at restore time to catch that would cost the memory of every photo at
/// once for a failure that still shows the page.
enum JPEGIntegrity {

    static func isComplete(_ data: Data) -> Bool {
        reachesEndOfImage(data) && imageIORecognises(data)
    }

    /// Walks marker segments until `FF D9`. Bytes after it are ignored, so a
    /// file with a trailer (some phones append one) still counts as whole.
    static func reachesEndOfImage(_ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            guard count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return false }

            var index = 2
            while index < count {
                guard bytes[index] == 0xFF else { return false }
                // Any number of 0xFF fill bytes may precede a marker.
                var markerIndex = index + 1
                while markerIndex < count, bytes[markerIndex] == 0xFF { markerIndex += 1 }
                guard markerIndex < count else { return false }
                let marker = bytes[markerIndex]
                index = markerIndex + 1

                switch marker {
                case 0xD9:
                    return true
                case 0x01, 0xD0...0xD7:
                    // Stand-alone markers carry no length.
                    continue
                case 0x00:
                    return false
                default:
                    guard index + 1 < count else { return false }
                    let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
                    guard length >= 2, index + length <= count else { return false }
                    index += length

                    guard marker == 0xDA else { continue }
                    // Start of scan: entropy-coded data follows, in which a
                    // literal 0xFF is always stuffed as `FF 00` and restart
                    // markers may appear. The first other marker ends the scan.
                    scan: while index < count {
                        guard bytes[index] == 0xFF else {
                            index += 1
                            continue
                        }
                        guard index + 1 < count else { return false }
                        switch bytes[index + 1] {
                        case 0x00, 0xD0...0xD7: index += 2
                        case 0xFF: index += 1
                        default: break scan
                        }
                    }
                }
            }
            return false
        }
    }

    static func imageIORecognises(_ data: Data) -> Bool {
        #if canImport(ImageIO)
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let type = CGImageSourceGetType(source) as String?,
            type == "public.jpeg",
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return false }
        return width > 0 && height > 0
        #else
        // No decoder to ask (the Linux slice package); the walk still stands.
        return true
        #endif
    }
}
