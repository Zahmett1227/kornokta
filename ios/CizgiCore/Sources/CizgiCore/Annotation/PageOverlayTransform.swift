import Foundation

/// Pure page/image coordinate conversion for an aspect-fit image. SwiftUI
/// views supply their current zoom and pan, but the geometry itself remains
/// testable without a view hierarchy or a device screen.
public struct PageOverlayTransform: Sendable, Equatable {
    public let imageWidth: Double
    public let imageHeight: Double
    public let viewportWidth: Double
    public let viewportHeight: Double
    public let zoom: Double
    public let panX: Double
    public let panY: Double

    public init(
        imageWidth: Double,
        imageHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double,
        zoom: Double = 1,
        panX: Double = 0,
        panY: Double = 0
    ) {
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.viewportWidth = viewportWidth
        self.viewportHeight = viewportHeight
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
    }

    public var scale: Double {
        guard imageWidth > 0, imageHeight > 0 else { return 0 }
        return min(viewportWidth / imageWidth, viewportHeight / imageHeight) * zoom
    }

    public var renderedWidth: Double { imageWidth * scale }
    public var renderedHeight: Double { imageHeight * scale }

    public var originX: Double { (viewportWidth - renderedWidth) / 2 + panX }
    public var originY: Double { (viewportHeight - renderedHeight) / 2 + panY }

    public func viewRect(for normalized: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: originX + normalized.x * imageWidth * scale,
            y: originY + normalized.y * imageHeight * scale,
            width: normalized.width * imageWidth * scale,
            height: normalized.height * imageHeight * scale
        )
    }

    public func normalizedPoint(viewX: Double, viewY: Double) -> (x: Double, y: Double)? {
        let renderedX = viewX - originX
        let renderedY = viewY - originY
        guard renderedX >= 0, renderedY >= 0, renderedX <= renderedWidth, renderedY <= renderedHeight else {
            return nil
        }
        return (renderedX / renderedWidth, renderedY / renderedHeight)
    }
}
