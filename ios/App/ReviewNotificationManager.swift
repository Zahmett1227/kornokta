import Foundation
import CizgiCore
#if canImport(UserNotifications)
import UserNotifications
#endif

/// The daily review reminder (ANA-PLAN §5.4, §6.7).
///
/// It used to be one repeating calendar trigger with fixed text, which fired
/// every day at the chosen hour whether or not a single card was due — and said
/// "bugün zamanı gelen kartlarını tamamla" on the days there were none. A
/// notification that is wrong often enough is one you learn to dismiss without
/// reading, which costs the app its only nudge.
///
/// iOS cannot evaluate a condition at fire time, so the counting happens in
/// advance: the app schedules one-shot reminders across the next few days, each
/// carrying the number of cards that will actually be due by then, and skips the
/// days with none. Every launch reschedules, which both refreshes the counts and
/// rolls the horizon forward.
///
/// The decision of *when* and *how many* lives in `ReviewReminderPlanner`
/// (CizgiCore) where it is unit-tested; this file is the iOS plumbing.
enum ReviewNotificationManager {
    /// Requests are identified by prefix so a reschedule can withdraw exactly
    /// its own, without disturbing anything else the app might add later.
    static let identifierPrefix = "cizgi.daily-review."
    /// Set on every reminder so the delegate can tell a review nudge from any
    /// other notification when deciding where to send the user.
    static let categoryIdentifier = "cizgi.review"

    /// Withdraws the previous reminders and schedules a fresh set.
    ///
    /// `dueDates` should already exclude suspended cards — a reminder counting
    /// cards the review screen will not show is the same lie in a new place.
    static func reschedule(
        enabled: Bool,
        hour: Int,
        dueDates: [Date],
        now: Date = .now
    ) async throws {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        await withdrawPending(from: center)

        guard enabled else {
            try? await center.setBadgeCount(0)
            return
        }
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw NotificationError.permissionDenied
        }

        // The badge is "due right now", which is a different question from what
        // any reminder asks, and the only number that is true at a glance.
        try? await center.setBadgeCount(
            ReviewReminderPlanner.badgeCount(dueDates: dueDates, now: now)
        )

        let reminders = ReviewReminderPlanner.reminders(dueDates: dueDates, hour: hour, from: now)
        let calendar = Calendar.current
        for (index, reminder) in reminders.enumerated() {
            let content = UNMutableNotificationContent()
            content.title = "Çizgi tekrar zamanı"
            content.body = reminder.body
            content.sound = .default
            content.categoryIdentifier = categoryIdentifier
            content.badge = NSNumber(value: reminder.dueCount)

            // A dated, non-repeating trigger: each day's text is different
            // because each day's count is, so there is nothing to repeat.
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: reminder.fireDate
            )
            let request = UNNotificationRequest(
                identifier: "\(identifierPrefix)\(index)",
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try await center.add(request)
        }
        #endif
    }

    #if canImport(UserNotifications)
    private static func withdrawPending(from center: UNUserNotificationCenter) async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        // The single repeating request the previous version used had no dot
        // suffix, so an app updated in place would otherwise keep firing it for
        // ever alongside the new ones.
        center.removePendingNotificationRequests(withIdentifiers: ours + ["cizgi.daily-review"])
    }
    #endif

    enum NotificationError: LocalizedError {
        case permissionDenied
        var errorDescription: String? { "Bildirim izni verilmedi. Ayarlar uygulamasından izin verebilirsin." }
    }
}

#if canImport(UserNotifications)
/// Sends a tapped reminder to the screen it is about.
///
/// Tapping it used to land on Yakala, because that is `AppNavigator`'s default
/// tab and nothing ever changed it — the one notification the app sends took the
/// user somewhere other than the thing it was reminding them to do.
@MainActor
final class ReviewNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    private let navigator: AppNavigator

    init(navigator: AppNavigator) {
        self.navigator = navigator
        super.init()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.notification.request.content.categoryIdentifier
            == ReviewNotificationManager.categoryIdentifier else { return }
        await MainActor.run {
            navigator.selectedTab = .review
        }
    }

    /// Shown even with the app open: the alternative is a reminder that
    /// silently does nothing because the user happened to be in the app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
#endif
