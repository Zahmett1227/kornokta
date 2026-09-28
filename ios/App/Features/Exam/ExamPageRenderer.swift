import Foundation
import PDFKit
import UIKit
import CizgiCore

/// Draws booklet pages and question crops from the packaged PDFs (plan §7.4 h).
///
/// An actor so the drawing happens off the main thread and the `PDFDocument`s
/// — which are not safe to share across threads — are only ever touched from
/// one place. At most three documents stay open: a session moves through one
/// or two booklets at a time, and a TUS booklet is a few megabytes each.
actor ExamPageRenderer {
    static let shared = ExamPageRenderer()

    private static let maxOpenDocuments = 3
    private var documents: [URL: PDFDocument] = [:]
    private var recentlyUsed: [URL] = []

    /// The whole page, with each region washed in `tint` — "Kaynağı göster".
    func page(pdf: URL, page number: Int, highlighting boxes: [[Double]], tint: UIColor, scale: CGFloat = 2) -> UIImage? {
        guard let page = document(at: pdf)?.page(at: number - 1) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            draw(page, bounds: bounds, scale: scale, in: context.cgContext, size: size)
            for bbox in boxes {
                guard let rect = ExamPageGeometry.imageRect(bbox: bbox, pageSize: bounds.size, imageSize: size) else {
                    continue
                }
                tint.withAlphaComponent(0.16).setFill()
                // `.normal`, spelled out: the plain `fill(_:)` copies the
                // colour in (UIRectFill's blend), and on an opaque page a 16%
                // wash became a black box over the very question it marked
                // (simulator, 2026-09-25).
                context.fill(rect, blendMode: .normal)
                tint.withAlphaComponent(0.7).setStroke()
                let outline = UIBezierPath(roundedRect: rect, cornerRadius: 4 * scale)
                outline.lineWidth = 1.5 * scale
                outline.stroke()
            }
        }
    }

    /// Only the question's box — the figure a `required` question cannot be
    /// answered without. Drawn at a higher scale than the page: an EKG strip
    /// has to survive a pinch.
    func crop(pdf: URL, page number: Int, bbox: [Double], scale: CGFloat = 3) -> UIImage? {
        guard let page = document(at: pdf)?.page(at: number - 1) else { return nil }
        let bounds = page.bounds(for: .mediaBox)
        let pageSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let rect = ExamPageGeometry.imageRect(bbox: bbox, pageSize: bounds.size, imageSize: pageSize) else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            draw(page, bounds: bounds, scale: scale, in: context.cgContext, size: pageSize)
        }
    }

    private func draw(_ page: PDFPage, bounds: CGRect, scale: CGFloat, in context: CGContext, size: CGSize) {
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        context.saveGState()
        // PDF space is bottom-left; the image is top-left.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
    }

    private func document(at url: URL) -> PDFDocument? {
        if let open = documents[url] {
            recentlyUsed.removeAll { $0 == url }
            recentlyUsed.append(url)
            return open
        }
        guard let opened = PDFDocument(url: url) else { return nil }
        documents[url] = opened
        recentlyUsed.append(url)
        while recentlyUsed.count > Self.maxOpenDocuments {
            documents.removeValue(forKey: recentlyUsed.removeFirst())
        }
        return opened
    }
}
