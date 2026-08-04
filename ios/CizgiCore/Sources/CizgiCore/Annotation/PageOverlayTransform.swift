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

    /// How far the image can pan in each direction before its edge would
    /// pull away from the viewport entirely. Independent of the current
    /// `panX`/`panY` — callers clamp a *candidate* pan against this.
    public var maxPanX: Double { max(0, (renderedWidth - viewportWidth) / 2) }
    public var maxPanY: Double { max(0, (renderedHeight - viewportHeight) / 2) }

    /// The nearest point still inside the rendered image, in view space —
    /// used to keep a live drag preview visually pinned to the edge instead
    /// of trailing off past it while the finger is still moving.
    public func clampedViewPoint(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        (
            min(max(viewX, originX), originX + renderedWidth),
            min(max(viewY, originY), originY + renderedHeight)
        )
    }

    public func viewRect(for normalized: NormalizedRect) -> NormalizedRect {
        NormalizedRect(
            x: originX + normalized.x * imageWidth * scale,
            y: originY + normalized.y * imageHeight * scale,
            width: normalized.width * imageWidth * scale,
            height: normalized.height * imageHeight * scale
        )
    }

    /// Clamps to the image bounds rather than failing outside them: a manual
    /// selection drag routinely overshoots the rendered image by a few points
    /// (letterboxing, finger overshoot on release), and returning `nil` there
    /// used to make the whole gesture vanish with no feedback instead of
    /// simply stopping at the edge.
    public func normalizedPoint(viewX: Double, viewY: Double) -> (x: Double, y: Double)? {
        guard renderedWidth > 0, renderedHeight > 0 else { return nil }
        let renderedX = min(max(viewX - originX, 0), renderedWidth)
        let renderedY = min(max(viewY - originY, 0), renderedHeight)
        return (renderedX / renderedWidth, renderedY / renderedHeight)
    }
}
