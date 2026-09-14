import SwiftUI
import CizgiCore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Tap target

/// The page photograph as it appears inside a card or a page — tappable, and
/// opening `SourceImageViewer` full screen.
///
/// Zoom lives in the full-screen viewer and not here, on purpose (2026-09-14).
/// Every place this sits is itself scrollable — the card face in a `ScrollView`,
/// the page detail in a `List` — and a pinch recogniser inside a scroll view
/// fights it: the page scrolls when you meant to pan, or the photo pans when
/// you meant to scroll. Photos solves the same problem the same way.
///
/// The image is decoded off the main thread, once per path. The views this
/// replaces decoded the full camera JPEG inside `body`, synchronously, on every
/// render — invisible while the photo was static, a stutter on every frame the
/// moment anything around it animates.
struct SourcePageImage: View {
    let path: String
    let imageStore: ImageStore
    /// Shown under the photo in the viewer (ders · tarih). Optional.
    var caption: String?
    var cornerRadius: CGFloat = Cizgi.Radius.sm

    @State private var image: UIImage?
    /// The file exists but would not decode. Shows nothing rather than a
    /// placeholder spinning for ever.
    @State private var failed = false
    @State private var isViewerPresented = false

    var body: some View {
        Group {
            if let image {
                Button {
                    isViewerPresented = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .stroke(Cizgi.hairline, lineWidth: 1)
                        )
                        // Says "this opens" without words. Without it the photo
                        // reads as an illustration, and the zoom the owner asked
                        // for would be there but undiscoverable.
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(7)
                                .background(.black.opacity(0.45), in: Circle())
                                .padding(Cizgi.Space.sm)
                                .accessibilityHidden(true)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sayfa fotoğrafı")
                .accessibilityHint("Tam ekran açar; iki parmakla yakınlaştırabilirsin.")
            } else if !failed {
                // Holds the space while decoding so the card does not jump when
                // the photo lands.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Cizgi.surfaceMuted)
                    .aspectRatio(0.72, contentMode: .fit)
                    .overlay { ProgressView() }
                    .accessibilityHidden(true)
            }
        }
        .task(id: path) {
            image = await Self.decode(url: imageStore.url(forRelativePath: path))
            failed = image == nil
        }
        .fullScreenCover(isPresented: $isViewerPresented) {
            if let image {
                SourceImageViewer(image: image, caption: caption)
            }
        }
    }

    /// Reads and fully decodes on a background thread. `preparingForDisplay`
    /// matters as much as the read: without it UIKit defers the JPEG decode to
    /// the first draw, which lands back on the main thread anyway.
    private static func decode(url: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(contentsOfFile: url.path) else { return nil }
            return image.preparingForDisplay() ?? image
        }.value
    }
}

// MARK: - Full-screen viewer

/// The page photo, full screen, behaving like Photos (2026-09-14).
///
/// What the owner asked for, in their own words: "iki elimi çektiğimde fotoğraf tekrar
/// küçülmesin". A SwiftUI `MagnifyGesture` springs back unless its end state is
/// committed by hand, and panning a magnified image then needs a second gesture
/// negotiated against the first. `UIScrollView` has done exactly this for fifteen
/// years — the zoom scale persists, the edges bounce, panning is free — so the
/// zooming is UIKit and only the chrome is SwiftUI.
///
/// Dismissal: the close button always; pulling down only while not zoomed, so a
/// pan inside a magnified page can never close it by accident.
struct SourceImageViewer: View {
    let image: UIImage
    var caption: String?

    @Environment(\.dismiss) private var dismiss
    @State private var isZoomed = false

    var body: some View {
        ZoomableImageView(image: image, isZoomed: $isZoomed) {
            dismiss()
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .padding(.trailing, Cizgi.Space.lg)
            .padding(.top, Cizgi.Space.sm)
            .accessibilityLabel("Kapat")
        }
        .overlay(alignment: .bottom) {
            // Hidden while zoomed: at 3× the caption sits over the very words
            // the owner zoomed in to read.
            if let caption, !isZoomed {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, Cizgi.Space.md)
                    .padding(.vertical, Cizgi.Space.sm)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, Cizgi.Space.lg)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isZoomed)
        // Clear, so pulling the page down fades it into the screen underneath
        // instead of into an opaque sheet — the cue that letting go closes it.
        .presentationBackground(.clear)
        .statusBarHidden()
        .accessibilityAction(.escape) { dismiss() }
    }
}

// MARK: - UIKit zoom

/// `UIScrollView` wrapped for SwiftUI. See `SourceImageViewer` for why UIKit.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    @Binding var isZoomed: Bool
    let onDismissRequest: () -> Void

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView(image: image)
        view.onZoomStateChange = { zoomed in
            // Deferred: this fires from inside UIKit's layout pass, and writing
            // SwiftUI state there is an "update during view update" warning.
            DispatchQueue.main.async {
                if isZoomed != zoomed { isZoomed = zoomed }
            }
        }
        view.onDismissRequest = onDismissRequest
        return view
    }

    func updateUIView(_ uiView: ZoomingImageScrollView, context: Context) {}
}

final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView = UIImageView()
    private var lastBoundsSize: CGSize = .zero
    private var reportedZoomed = false

    var onZoomStateChange: ((Bool) -> Void)?
    var onDismissRequest: (() -> Void)?

    /// How far a pull must travel to close, in points. Past half of it, a quick
    /// flick is enough.
    private let dismissDistance: CGFloat = 120

    init(image: UIImage) {
        super.init(frame: .zero)
        delegate = self
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        decelerationRate = .fast
        bouncesZoom = true
        // Vertical bounce even when the fitted page is shorter than the screen:
        // it is what lets a pull-down be felt, and read, before it closes.
        alwaysBounceVertical = true
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .black

        imageView.image = image
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = "Sayfa fotoğrafı"
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Fit only when the viewport actually changes size — laying out on
        // every pass would snap a zoomed page back to 1×, the exact behaviour
        // this view exists to avoid.
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            fitToBounds()
        }
    }

    private var isAtMinimum: Bool { zoomScale <= minimumZoomScale + 0.01 }

    private func fitToBounds() {
        guard let image = imageView.image,
              image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return }

        zoomScale = 1
        let fit = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted

        minimumZoomScale = 1
        // Enough to read a margin note on a camera photo: at least 4×, and up to
        // twice the photo's own pixel density so a sharp capture can be used in
        // full. Beyond that there is nothing left to see but JPEG blocks.
        let nativeScale = (image.size.width * image.scale) / fitted.width
        maximumZoomScale = max(4, nativeScale * 2)
        zoomScale = 1
        centerContent()
    }

    /// Keeps a page smaller than the screen in the middle of it. A scroll view
    /// pins its content to the top-left; insets are the standard way to centre
    /// it, recomputed on every zoom step.
    private func centerContent() {
        let content = imageView.frame.size
        let insetX = max(0, (bounds.width - content.width) / 2)
        let insetY = max(0, (bounds.height - content.height) / 2)
        contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if isAtMinimum {
            let target = min(maximumZoomScale, 2.5)
            let point = recognizer.location(in: imageView)
            let size = CGSize(width: bounds.width / target, height: bounds.height / target)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                            width: size.width, height: size.height),
                 animated: true)
        } else {
            setZoomScale(minimumZoomScale, animated: true)
        }
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        let zoomed = !isAtMinimum
        if zoomed != reportedZoomed {
            reportedZoomed = zoomed
            onZoomStateChange?(zoomed)
        }
    }

    /// How far the page has been pulled below its resting place, in points.
    private var pullDistance: CGFloat {
        max(0, -(contentOffset.y + contentInset.top))
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard isAtMinimum else {
            backgroundColor = .black
            return
        }
        // The fade is the feedback: the further the pull, the more of the card
        // underneath shows through.
        let progress = min(1, pullDistance / (dismissDistance * 2))
        backgroundColor = UIColor.black.withAlphaComponent(1 - progress * 0.7)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard isAtMinimum else { return }
        // Velocity is negative when the finger moves down.
        let flicked = pullDistance > dismissDistance / 2 && velocity.y < -1.2
        if pullDistance > dismissDistance || flicked {
            onDismissRequest?()
        }
    }
}
