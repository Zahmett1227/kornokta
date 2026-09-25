import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Turns a question's `bbox` into the rectangles the phone draws (plan §6).
///
/// The bank stores pdfplumber's `[x0, top, x1, bottom]`: points, origin at the
/// page's top-left. PDFKit's page space has its origin at the bottom-left, so
/// `y = pageHeight − bottom`. The packager only ships pages without an offset
/// crop box or a rotation (gate V8), which is what makes this one subtraction
/// enough.
public enum ExamPageGeometry {
    /// Breathing room around a crop, in points — a box drawn tight to the
    /// text clips the descenders of its last line.
    public static let cropPadding: Double = 6

    /// The region in PDF page space (bottom-left origin), or `nil` for a
    /// malformed box.
    public static func pdfRect(bbox: [Double], pageHeight: Double) -> CGRect? {
        guard let box = normalized(bbox) else { return nil }
        return CGRect(x: box.x0, y: pageHeight - box.bottom, width: box.x1 - box.x0, height: box.bottom - box.top)
    }

    /// The region in a rendered image of the page (top-left origin), scaled
    /// from points to the image's pixels, padded and kept on the page.
    public static func imageRect(
        bbox: [Double],
        pageSize: CGSize,
        imageSize: CGSize,
        padding: Double = cropPadding
    ) -> CGRect? {
        guard let box = normalized(bbox), pageSize.width > 0, pageSize.height > 0 else { return nil }
        let scaleX = Double(imageSize.width / pageSize.width)
        let scaleY = Double(imageSize.height / pageSize.height)
        let x0 = max(0, box.x0 - padding)
        let top = max(0, box.top - padding)
        let x1 = min(Double(pageSize.width), box.x1 + padding)
        let bottom = min(Double(pageSize.height), box.bottom + padding)
        guard x1 > x0, bottom > top else { return nil }
        return CGRect(x: x0 * scaleX, y: top * scaleY, width: (x1 - x0) * scaleX, height: (bottom - top) * scaleY)
    }

    private static func normalized(_ bbox: [Double]) -> (x0: Double, top: Double, x1: Double, bottom: Double)? {
        guard bbox.count == 4, bbox.allSatisfy(\.isFinite) else { return nil }
        let (x0, top, x1, bottom) = (bbox[0], bbox[1], bbox[2], bbox[3])
        guard x1 > x0, bottom > top else { return nil }
        return (x0, top, x1, bottom)
    }
}
