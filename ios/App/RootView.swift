import SwiftUI
import SwiftData
import CizgiCore
#if canImport(UserNotifications)
import UserNotifications
#endif

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var navigator = AppNavigator()
    @Query private var cards: [Card]
    /// Held for the lifetime of the scene: `UNUserNotificationCenter.delegate`
    /// is a weak reference, so a locally-created delegate would be deallocated
    /// immediately and tapped reminders would go nowhere.
    @State private var notificationDelegate: ReviewNotificationDelegate?

    /// Due dates of the cards a reminder may legitimately count — suspended
    /// ones are excluded because the review screen will not show them either.
    private var reviewableDueDates: [Date] {
        cards.filter { $0.status == .active }.map(\.dueDate)
    }

    var body: some View {
        // The native tab bar cannot give the centre destination the visual
        // priority Egzersiz needs, so `CizgiRootTabBar` replaces it. Two rules
        // keep that swap honest:
        //
        // 1. `.toolbar(.hidden, for: .tabBar)` goes on each *child* of the
        //    TabView, which is the placement that hides this TabView's own bar.
        //    On the TabView itself it addresses an enclosing tab bar — of which
        //    there is none — so the native bar would have stayed. The
        //    `.tabItem` labels are kept as the fallback that failure mode
        //    deserves: a labelled bar, never five blank items.
        // 2. The replacement is attached per tab root (`rootTabBarInset`),
        //    *inside* each NavigationStack. A pushed screen is then simply a
        //    different view and loses the bar with no bookkeeping. Pushes are
        //    value-based now, so `NavigationPath.isEmpty` would also be
        //    correct — but placement needs no flag to keep in sync at all,
        //    which is why it stays.
        TabView(selection: $navigator.selectedTab) {
            CaptureView()
                .tabItem { Label("Yakala", systemImage: "camera") }
                .tag(AppNavigator.RootTab.capture)
                .toolbar(.hidden, for: .tabBar)

            ReviewView()
                .tabItem { Label("Tekrar", systemImage: "rectangle.stack") }
                .tag(AppNavigator.RootTab.review)
                .toolbar(.hidden, for: .tabBar)

            ExerciseView()
                .tabItem { Label("Egzersiz", systemImage: "brain.head.profile") }
                .tag(AppNavigator.RootTab.exercise)
                .toolbar(.hidden, for: .tabBar)

            LibraryView()
                .tabItem { Label("Bilgilerim", systemImage: "books.vertical") }
                .tag(AppNavigator.RootTab.library)
                .toolbar(.hidden, for: .tabBar)

            SettingsView()
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                .tag(AppNavigator.RootTab.settings)
                .toolbar(.hidden, for: .tabBar)
        }
        .tint(Cizgi.accent)
        .environmentObject(navigator)
        .task {
            installNotificationDelegate()
            // Pick up anything left unfinished by a previous launch (§24.1:
            // pending work must survive the app closing).
            await environment.queue.processPending()
            await refreshReminders()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // iOS may suspend networking immediately after the app leaves the
                // foreground. Re-scan the durable queue whenever it becomes
                // active; idempotence in ProcessingQueue prevents duplicate cards.
                Task { await environment.queue.processPending() }
            case .background:
                // Rescheduling on the way out is what keeps the counts true and
                // the horizon rolling: the reminders are dated one-shots
                // computed from the due dates as they stand right now.
                Task { await refreshReminders() }
            default:
                break
            }
        }
    }

    private func installNotificationDelegate() {
        #if canImport(UserNotifications)
        guard notificationDelegate == nil else { return }
        let delegate = ReviewNotificationDelegate(navigator: navigator)
        notificationDelegate = delegate
        UNUserNotificationCenter.current().delegate = delegate
        #endif
    }

    /// Silent by design: a failure here means the user revoked notification
    /// permission outside the app, which Ayarlar reports the next time the
    /// toggle is touched. Interrupting a launch over it would be worse.
    private func refreshReminders() async {
        try? await ReviewNotificationManager.reschedule(
            enabled: environment.settings.notificationsEnabled,
            hour: environment.settings.notificationHour,
            dueDates: reviewableDueDates
        )
    }
}

/// Attaches the replacement root bar to a tab's root content.
///
/// Must be applied *inside* the tab's `NavigationStack`, to the root screen
/// only. That placement is what makes depth handling free: a pushed detail
/// screen is a different view, so it never receives the inset and the bar goes
/// away on its own — no flag to keep in sync. (Since the value-based
/// navigation refactor the bound paths do track depth, so `isEmpty` would work
/// too; placement simply needs no bookkeeping at all.)
struct RootTabBarInset: ViewModifier {
    @EnvironmentObject private var navigator: AppNavigator

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !navigator.isTabBarHidden {
                    CizgiRootTabBar(selection: $navigator.selectedTab)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: navigator.isTabBarHidden)
    }
}

extension View {
    func rootTabBarInset() -> some View { modifier(RootTabBarInset()) }
}

/// A five-destination root bar with Egzersiz as the unmistakable centre of the
/// app.
///
/// Three things this deliberately does *not* do:
///
/// - It does not raise the centre item with `.offset`. An offset moves pixels
///   but not layout, so the visibly protruding top of the most important
///   button was outside the parent's `contentShape` and simply did not respond
///   to taps — and it drew past the `safeAreaInset` this bar reserves, over the
///   content above. The lift here is real layout: a taller icon well plus
///   `alignment: .bottom`, so the hit area is exactly what the eye sees.
/// - It does not use fixed point sizes. The wells scale with Dynamic Type
///   (`@ScaledMetric`), labels shrink before they truncate, and at
///   accessibility sizes the labels drop away entirely rather than wrapping
///   five ways across the width — the icons and VoiceOver labels carry it.
/// - It does not give Egzersiz a permanently "on" look. A centre item that is
///   always filled amber cannot tell the user which tab they are on, which is
///   the one job a tab bar has.
private struct CizgiRootTabBar: View {
    private struct Item: Identifiable {
        var id: AppNavigator.RootTab { tab }
        let tab: AppNavigator.RootTab
        let title: String
        let icon: String
        let selectedIcon: String
    }

    @Binding var selection: AppNavigator.RootTab
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Both wells grow with the text size, keeping the lift proportional.
    @ScaledMetric(relativeTo: .body) private var well: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var centreWell: CGFloat = 52

    private let tabs: [Item] = [
        Item(tab: .capture, title: "Yakala", icon: "camera", selectedIcon: "camera.fill"),
        Item(tab: .review, title: "Tekrar", icon: "rectangle.stack", selectedIcon: "rectangle.stack.fill"),
        // Same glyph in both states on purpose: the disc behind it is the
        // selection indicator here, and a `.fill` variant of this symbol is not
        // something to rely on across OS versions.
        Item(tab: .exercise, title: "Egzersiz", icon: "brain.head.profile", selectedIcon: "brain.head.profile"),
        Item(tab: .library, title: "Bilgilerim", icon: "books.vertical", selectedIcon: "books.vertical.fill"),
        Item(tab: .settings, title: "Ayarlar", icon: "gearshape", selectedIcon: "gearshape.fill"),
    ]

    private var showsLabels: Bool { !dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(tabs) { item in
                tabButton(item)
            }
        }
        .padding(.horizontal, Cizgi.Space.xs)
        // Room for the centre well to stand above the others without leaving
        // the bar's own bounds.
        .padding(.top, (centreWell - well) / 2 + Cizgi.Space.xs)
        .padding(.bottom, Cizgi.Space.xs)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Cizgi.hairline).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: -4)
    }

    private func tabButton(_ item: Item) -> some View {
        let isSelected = selection == item.tab
        let isCentre = item.tab == .exercise
        return Button {
            selection = item.tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: isSelected ? item.selectedIcon : item.icon)
                    .font(isCentre ? .title3.weight(.bold) : .body.weight(.semibold))
                    .foregroundStyle(centreForeground(isCentre: isCentre, isSelected: isSelected))
                    .frame(width: isCentre ? centreWell : well,
                           height: isCentre ? centreWell : well)
                    .background { centreBackground(isCentre: isCentre, isSelected: isSelected) }

                if showsLabels {
                    Text(item.title)
                        .font(.caption2.weight(isSelected ? .bold : .medium))
                        .foregroundStyle(isSelected ? Cizgi.ink : Cizgi.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func centreForeground(isCentre: Bool, isSelected: Bool) -> Color {
        if isCentre { return isSelected ? Cizgi.ink : Cizgi.accent }
        return isSelected ? Cizgi.accent : Cizgi.muted
    }

    /// Selected Egzersiz is a filled amber disc; unselected is the same disc
    /// outlined. It still reads as the primary destination at a glance, and it
    /// can still say "you are not here".
    @ViewBuilder
    private func centreBackground(isCentre: Bool, isSelected: Bool) -> some View {
        if isCentre {
            if isSelected {
                Circle()
                    .fill(Cizgi.accent)
                    .shadow(color: Cizgi.accent.opacity(0.38), radius: 10, y: 4)
            } else {
                Circle()
                    .fill(Cizgi.accentSoft)
                    .overlay(Circle().stroke(Cizgi.accent, lineWidth: 2))
            }
        }
    }
}

/// Semantic colours from §29. Status is never conveyed by colour alone — every
/// use pairs it with a label or an icon.
extension ProcessingState {
    var tint: Color {
        switch self {
        case .ready: return .green
        case .confirmationRequired: return .orange
        case .permanentFailure: return .red
        case .cancelled: return .gray
        case .temporaryFailure: return .orange
        default: return .blue
        }
    }

    var label: String {
        switch self {
        case .captured: return "Bekliyor"
        case .localPreprocessing: return "Hazırlanıyor"
        // Not "Yerel OCR": there has been no local OCR since the ADR-005 trim.
        // `.localOCR` survives as the enum case the vision flow reuses for "in
        // flight" (ProcessingQueue.process), and a row reading "Yerel OCR"
        // while the page is at OpenAI sent every cost investigation looking in
        // the wrong place. Renaming the case itself would migrate every stored
        // `processingStateRaw`; renaming what the human reads costs nothing.
        case .localOCR: return "Modele gönderildi"
        case .markerDetection: return "İşaret aranıyor"
        case .cloudOCR: return "Bulut OCR"
        case .transcriptionReconciliation: return "Doğrulanıyor"
        case .confirmationRequired: return "Onay gerekli"
        case .cardGeneration: return "Kart oluşturuluyor"
        case .qualityValidation: return "Kalite kontrolü"
        case .ready: return "Hazır"
        case .temporaryFailure: return "Geçici hata"
        case .permanentFailure: return "Hata"
        case .cancelled: return "İptal edildi"
        }
    }

    var systemImage: String {
        switch self {
        case .ready: return "checkmark.circle.fill"
        case .confirmationRequired: return "hand.raised.fill"
        case .permanentFailure: return "xmark.octagon.fill"
        case .temporaryFailure: return "arrow.clockwise.circle.fill"
        case .cancelled: return "slash.circle"
        default: return "clock.fill"
        }
    }
}
