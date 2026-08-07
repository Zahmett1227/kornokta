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
        TabView(selection: $navigator.selectedTab) {
            CaptureView()
                .tabItem { Label("Yakala", systemImage: "camera") }
                .tag(AppNavigator.RootTab.capture)

            ReviewView()
                .tabItem { Label("Tekrar", systemImage: "rectangle.stack") }
                .tag(AppNavigator.RootTab.review)

            LibraryView()
                .tabItem { Label("Bilgilerim", systemImage: "books.vertical") }
                .tag(AppNavigator.RootTab.library)

            SettingsView()
                .tabItem { Label("Ayarlar", systemImage: "gearshape") }
                .tag(AppNavigator.RootTab.settings)
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
