import SwiftUI
import CizgiCore

extension CizgiSubject {
    /// One public-domain engraving per subject (docs/FIGURES-SOURCES.md), in
    /// `Assets.xcassets/Figures`. The subject's figure is part of its identity
    /// the way its colour is: the same drawing behind every card of that ders.
    var figureAssetName: String {
        switch self {
        case .anatomi: return "Figures/anatomi"
        case .fizyoloji: return "Figures/fizyoloji"
        case .biyokimya: return "Figures/biyokimya"
        case .farmakoloji: return "Figures/farmakoloji"
        case .mikrobiyoloji: return "Figures/mikrobiyoloji"
        case .patoloji: return "Figures/patoloji"
        case .dahiliye: return "Figures/dahiliye"
        case .cerrahi: return "Figures/cerrahi"
        case .kadinDogum: return "Figures/kadindogum"
        case .pediatri: return "Figures/pediatri"
        case .kucukStajlar: return "Figures/kucukstajlar"
        }
    }
}

/// The faint engraving behind a question (2026-09-14).
///
/// The owner's brief: the question screen should not look empty, it should look
/// considered — "arka planda, aşırı belli olmayan, resim gibi değil". So this is
/// printed in the ink colour at a few percent opacity rather than shown as an
/// image, and bleeds off the bottom-right edge like an illustration set into the
/// margin of a page rather than a picture placed on it.
///
/// Rendered as a template, so it follows the theme on its own: dark ink on bone
/// paper in light mode, pale ink on night blue in dark mode, at the same
/// faintness in both.
struct SubjectFigure: View {
    let subject: CizgiSubject

    /// Faint enough that text scrolling over it stays fully legible, strong
    /// enough to register as a drawing and not as a stain.
    static let opacity = 0.07

    var body: some View {
        Image(subject.figureAssetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(Cizgi.ink.opacity(Self.opacity))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Places the subject's figure behind this view, anchored bottom-right.
    ///
    /// Shown only while it has room and nothing to compete with: a question
    /// without its answer yet, not a five-option card (the options fill the
    /// space), not at accessibility text sizes (the text fills it), and not for
    /// a card with no recognised subject (there is no figure to choose).
    func subjectFigureBackground(_ subject: CizgiSubject?, isVisible: Bool) -> some View {
        background(alignment: .bottomTrailing) {
            if let subject, isVisible {
                SubjectFigure(subject: subject)
                    .containerRelativeFrame(.horizontal) { width, _ in width * 0.62 }
                    .frame(maxHeight: 420, alignment: .bottomTrailing)
                    // Past the edge on purpose: a whole drawing centred in the
                    // gap reads as a picture; one cut by the margin reads as
                    // part of the page.
                    .offset(x: 28, y: 12)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isVisible)
    }
}
