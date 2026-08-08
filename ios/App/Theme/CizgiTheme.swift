import SwiftUI
import CizgiCore
#if canImport(UIKit)
import UIKit
#endif

/// Çizgi's "warm study" design system (Faz 6 B3/UI).
///
/// Brand-aligned with the app icon: an amber highlighter accent over navy ink
/// on a warm-paper ground. Everything here is derived, light+dark aware, and
/// asset-catalog-free so the whole palette lives in one file. Status is never
/// colour-only — call sites pair a tint with a label or an SF Symbol.
enum Cizgi {

    // MARK: Colour

    /// Amber highlighter — the one accent. Actions, selection, the marker motif.
    static let accent = dyn((0.90, 0.62, 0.13), (0.96, 0.72, 0.26))
    /// Translucent amber for chips, highlighter strips, soft fills.
    static let accentSoft = dyn((0.98, 0.90, 0.72), (0.42, 0.32, 0.12))
    /// Navy ink — primary text and headings.
    static let ink = dyn((0.09, 0.13, 0.24), (0.91, 0.93, 0.98))
    /// Secondary text.
    static let muted = dyn((0.42, 0.45, 0.52), (0.62, 0.66, 0.74))
    /// Screen background — warm paper.
    static let paper = dyn((0.97, 0.95, 0.91), (0.07, 0.08, 0.11))
    /// Raised card surface.
    static let surface = dyn((1.0, 1.0, 1.0), (0.11, 0.13, 0.17))
    /// Muted surface (stat tiles, inset rows).
    static let surfaceMuted = dyn((0.94, 0.92, 0.87), (0.14, 0.16, 0.21))
    /// Hairline separators / card borders.
    static let hairline = dyn((0.86, 0.83, 0.77), (0.20, 0.23, 0.29))

    static let success = dyn((0.20, 0.55, 0.34), (0.40, 0.78, 0.53))
    static let warning = dyn((0.85, 0.55, 0.13), (0.96, 0.72, 0.30))
    static let danger = dyn((0.76, 0.24, 0.22), (0.94, 0.45, 0.42))

    // MARK: Spacing / shape

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
    }

    /// Amber → soft-amber highlighter gradient, the recurring marker motif.
    static var highlighter: LinearGradient {
        LinearGradient(
            colors: [accent, accentSoft],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Dynamic colour helper

#if canImport(UIKit)
private func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(uiColor: UIColor { traits in
        let c = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
    })
}
#else
private func dyn(_ light: (Double, Double, Double), _ dark: (Double, Double, Double)) -> Color {
    Color(red: light.0, green: light.1, blue: light.2)
}
#endif

// MARK: - Reusable components

/// A rounded "paper" card with a soft shadow and an optional leading
/// highlighter strip — the surface every screen builds on.
struct CardSurface<Content: View>: View {
    var highlighted: Bool = false
    var padding: CGFloat = Cizgi.Space.lg
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) {
            if highlighted {
                Cizgi.highlighter
                    .frame(width: 5)
            }
            content()
                .padding(padding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Cizgi.surface)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                .stroke(Cizgi.hairline, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 10, x: 0, y: 4)
    }
}

/// A thin amber highlighter underline — used as a section/word accent.
struct HighlighterStrip: View {
    var width: CGFloat = 44
    var body: some View {
        Capsule()
            .fill(Cizgi.highlighter)
            .frame(width: width, height: 5)
    }
}

/// A soft amber-tinted tag capsule.
struct TagChip: View {
    let text: String
    var systemImage: String?
    init(_ text: String, systemImage: String? = nil) {
        self.text = text
        self.systemImage = systemImage
    }
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(Cizgi.ink)
        .padding(.horizontal, Cizgi.Space.sm)
        .padding(.vertical, Cizgi.Space.xs)
        .background(Cizgi.accentSoft, in: Capsule())
    }
}

/// A small labelled statistic tile.
struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(Cizgi.ink)
            Text(label)
                .font(.caption)
                .foregroundStyle(Cizgi.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Cizgi.Space.md)
        .background(Cizgi.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.sm, style: .continuous))
    }
}

/// Shared hierarchy for root-screen introductions. Keeping the eyebrow, title
/// and supporting copy aligned prevents every feature from inventing a new
/// visual language as the app grows.
struct ScreenHero: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    let systemImage: String

    var body: some View {
        CardSurface(highlighted: true, padding: Cizgi.Space.xl) {
            HStack(alignment: .top, spacing: Cizgi.Space.lg) {
                VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                    Text(eyebrow.uppercased())
                        .font(.caption2.weight(.bold))
                        .tracking(1.1)
                        .foregroundStyle(Cizgi.accent)
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Cizgi.ink)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Cizgi.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Cizgi.ink)
                    .frame(width: 58, height: 58)
                    .background(Cizgi.accent, in: Circle())
            }
        }
    }
}

struct CizgiSectionTitle: View {
    let title: String
    var subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Cizgi.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(Cizgi.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Compact root-screen action used for quick starts and cross-feature jumps.
struct FeatureActionCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Cizgi.Space.sm) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isProminent ? Cizgi.ink : Cizgi.accent)
                Spacer(minLength: Cizgi.Space.xs)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Cizgi.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Cizgi.muted)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            .padding(Cizgi.Space.lg)
            .background(isProminent ? Cizgi.accentSoft : Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                    .stroke(isProminent ? Cizgi.accent.opacity(0.7) : Cizgi.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Button styles

/// The primary amber action button.
struct CizgiPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color(red: 0.09, green: 0.13, blue: 0.24))
            .frame(maxWidth: .infinity)
            .padding(.vertical, Cizgi.Space.lg)
            .background(Cizgi.accent)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .shadow(color: Cizgi.accent.opacity(0.35), radius: 10, x: 0, y: 5)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A bordered secondary button on the paper ground.
struct CizgiSecondaryButtonStyle: ButtonStyle {
    var tint: Color = Cizgi.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Cizgi.Space.md)
            .background(Cizgi.surface)
            .clipShape(RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Cizgi.Radius.md, style: .continuous)
                    .stroke(tint.opacity(0.4), lineWidth: 1.5)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Card type display (§14 types → Turkish label, icon, tint)

extension CardType {
    var displayName: String {
        switch self {
        case .directRecall: return "Hatırlama"
        case .cloze: return "Boşluk"
        case .mechanism: return "Mekanizma"
        case .distinction: return "Ayırt etme"
        case .exceptionTrap: return "İstisna"
        case .multipleChoice: return "Beş şık"
        }
    }

    var icon: String {
        switch self {
        case .directRecall: return "brain.head.profile"
        case .cloze: return "rectangle.dashed"
        case .mechanism: return "gearshape.2"
        case .distinction: return "arrow.left.and.right"
        case .exceptionTrap: return "exclamationmark.triangle"
        case .multipleChoice: return "list.bullet.circle"
        }
    }
}

/// A compact badge naming the card's type.
struct CardTypeBadge: View {
    let type: CardType
    var body: some View {
        Label(type.displayName, systemImage: type.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Cizgi.accent)
            .padding(.horizontal, Cizgi.Space.sm)
            .padding(.vertical, 3)
            .background(Cizgi.accentSoft.opacity(0.6), in: Capsule())
    }
}

// MARK: - Review rating colour

extension ReviewRating {
    var tint: Color {
        switch self {
        case .again: return Cizgi.danger
        case .hard: return Cizgi.warning
        case .good: return Cizgi.success
        case .easy: return Cizgi.accent
        }
    }
}
