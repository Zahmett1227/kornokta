#if os(iOS)
import SwiftUI
import CizgiCore

/// The one-tap "which page did you mean?" step.
///
/// Why it exists at all is in `PageSplit`: the document camera's viewfinder
/// shows less than it captures, and its edge detection reads an open book as a
/// single document, so a shot framed on one page arrives holding two.
///
/// This is deliberately *not* the Faz 6 confirmation screen coming back. It
/// never shows card content and it cannot reject a page — it asks about framing
/// only, it appears only when the capture actually looks like a spread, and the
/// answer is a single tap. Cards still enter the deck unreviewed.
struct PageCropView: View {
    let image: UIImage
    /// Position within the spreads of this batch, 1-based, for the counter.
    let position: Int
    let total: Int
    let onConfirm: (PageSplit.Selection, Double) -> Void
    let onCancel: () -> Void

    /// No default selection is "safe" here, so the one that is *reversible by
    /// looking* wins: the left page is the one the eye lands on first, and the
    /// dimmed half makes a wrong guess obvious before the tap.
    @State private var selection: PageSplit.Selection = .left
    @State private var splitRatio = PageSplit.defaultSplitRatio

    var body: some View {
        NavigationStack {
            VStack(spacing: Cizgi.Space.lg) {
                header
                page
                controls
            }
            .padding(Cizgi.Space.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Cizgi.paper.ignoresSafeArea())
            .navigationTitle("Sayfayı seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Nothing is on disk yet, so this really does discard the
                    // batch — same contract as the duplicate question's
                    // "Vazgeç", and named the same way for that reason.
                    Button("Vazgeç", role: .cancel, action: onCancel)
                }
            }
        }
        .tint(Cizgi.accent)
    }

    // MARK: Pieces

    private var header: some View {
        VStack(spacing: Cizgi.Space.xs) {
            if total > 1 {
                Text("\(position) / \(total)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Cizgi.muted)
            }
            Text("Fotoğrafa iki sayfa girmiş")
                .font(.headline)
                .foregroundStyle(Cizgi.ink)
            Text("Kartlar yalnız seçtiğin sayfadan üretilir.")
                .font(.subheadline)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var page: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            // The overlay inherits this view's frame, and `scaledToFit` makes
            // that frame the drawn image's own bounds — which is what lets the
            // divider's x be read straight back as a ratio of the image width.
            .overlay { splitOverlay }
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous)
                    .stroke(Cizgi.hairline, lineWidth: 1)
            )
            .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private var splitOverlay: some View {
        if selection == .whole {
            EmptyView()
        } else {
            GeometryReader { geometry in
                let width = geometry.size.width
                let cut = width * splitRatio

                ZStack(alignment: .topLeading) {
                    // The half being thrown away is dimmed rather than hidden:
                    // the user has to be able to check they are keeping the
                    // page they marked, and that needs both halves visible.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: selection == .left ? max(width - cut, 0) : max(cut, 0))
                        .offset(x: selection == .left ? cut : 0)

                    divider(height: geometry.size.height, x: cut)
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(width: width))
            }
        }
    }

    private func divider(height: CGFloat, x: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Cizgi.accent)
                .frame(width: 2, height: height)
            Circle()
                .fill(Cizgi.accent)
                .frame(width: 28, height: 28)
                .overlay(
                    Image(systemName: "arrow.left.and.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        }
        // VoiceOver cannot drag a line. The adjustable action gives the same
        // control in steps — without it the cut would be stuck at its default
        // for anyone not using touch. Applied before `.position`, so the
        // element VoiceOver reports is the handle rather than the whole page.
        .accessibilityElement()
        .accessibilityLabel("Sayfaları ayıran çizgi")
        .accessibilityValue("yüzde \(Int((splitRatio * 100).rounded()))")
        .accessibilityAdjustableAction { direction in
            let step = 0.02
            switch direction {
            case .increment: splitRatio = PageSplit.clampedSplitRatio(splitRatio + step)
            case .decrement: splitRatio = PageSplit.clampedSplitRatio(splitRatio - step)
            @unknown default: break
            }
        }
        .position(x: x, y: height / 2)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        // `minimumDistance: 0` so a tap anywhere on the page moves the line
        // there — hunting for a 28-point handle is not what this step is for.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard width > 0 else { return }
                splitRatio = PageSplit.clampedSplitRatio(Double(value.location.x / width))
            }
    }

    private var controls: some View {
        VStack(spacing: Cizgi.Space.md) {
            Picker("Sayfa", selection: $selection) {
                Text("Sol sayfa").tag(PageSplit.Selection.left)
                Text("Sağ sayfa").tag(PageSplit.Selection.right)
                Text("Tümü").tag(PageSplit.Selection.whole)
            }
            .pickerStyle(.segmented)

            Text(selection == .whole
                 ? "Sayfa olduğu gibi gönderilir."
                 : "Çizgiyi sürükleyerek ayırma yerini değiştirebilirsin.")
                .font(.footnote)
                .foregroundStyle(Cizgi.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button("Devam") { onConfirm(selection, splitRatio) }
                .buttonStyle(CizgiPrimaryButtonStyle())
        }
    }
}
#endif
