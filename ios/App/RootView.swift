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
        //    different view and loses the bar with no bookkeeping — no depth
        //    flag and no `NavigationPath.isEmpty` check, neither of which this
        //    app can answer correctly (see `AppNavigator`).
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
/// away on its own. Deriving the same thing from `NavigationPath.isEmpty` does
/// not work here — every push in this app is a view-based `NavigationLink`,
/// which leaves the bound path empty, so the bar would have stayed on every
/// detail screen (the exact overlap `ConfirmationView` once had to work around,
/// and whose `.toolbar(.hidden, for: .tabBar)` no longer applies to a bar that
/// is not the TabView's).
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
/// app. It deliberately uses buttons rather than gestures so Dynamic Type,
/// VoiceOver and the 44-point minimum target all work without special cases.
private struct CizgiRootTabBar: View {
    private struct Item: Identifiable {
        var id: AppNavigator.RootTab { tab }
        let tab: AppNavigator.RootTab
        let title: String
        let icon: String
    }

    @Binding var selection: AppNavigator.RootTab

    private let tabs: [Item] = [
        Item(tab: .capture, title: "Yakala", icon: "camera"),
        Item(tab: .review, title: "Tekrar", icon: "rectangle.stack"),
        Item(tab: .exercise, title: "Egzersiz", icon: "brain.head.profile"),
        Item(tab: .library, title: "Bilgilerim", icon: "books.vertical"),
        Item(tab: .settings, title: "Ayarlar", icon: "gearshape"),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(tabs) { item in
                tabButton(item.tab, title: item.title, icon: item.icon)
            }
        }
        .padding(.horizontal, Cizgi.Space.xs)
        .padding(.top, Cizgi.Space.sm)
        .padding(.bottom, Cizgi.Space.xs)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Cizgi.hairline).frame(height: 1)
        }
        .shadow(color: .black.opacity(0.08), radius: 12, y: -4)
    }

    private func tabButton(
        _ tab: AppNavigator.RootTab,
        title: String,
        icon: String
    ) -> some View {
        let isSelected = selection == tab
        let isExercise = tab == .exercise
        return Button {
            selection = tab
        } label: {
            VStack(spacing: isExercise ? 3 : 4) {
                Image(systemName: isSelected ? selectedIcon(icon) : icon)
                    .font(isExercise ? .title2.weight(.bold) : .body.weight(.semibold))
                    .frame(width: isExercise ? 52 : 28, height: isExercise ? 52 : 28)
                    .foregroundStyle(isExercise ? Cizgi.ink : (isSelected ? Cizgi.accent : Cizgi.muted))
                    .background {
                        if isExercise {
                            Circle()
                                .fill(Cizgi.accent)
                                .shadow(color: Cizgi.accent.opacity(0.38), radius: 10, y: 4)
                        }
                    }
                    .offset(y: isExercise ? -10 : 0)

                Text(title)
                    .font(.caption2.weight(isSelected || isExercise ? .bold : .medium))
                    .foregroundStyle(isSelected ? Cizgi.ink : Cizgi.muted)
                    .offset(y: isExercise ? -8 : 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 52)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedIcon(_ icon: String) -> String {
        switch icon {
        case "camera": return "camera.fill"
        case "rectangle.stack": return "rectangle.stack.fill"
        case "brain.head.profile": return "brain.head.profile"
        case "books.vertical": return "books.vertical.fill"
        case "gearshape": return "gearshape.fill"
        default: return icon
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
        case .localOCR: return "Yerel OCR"
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
