import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

enum ReviewNotificationManager {
    static let identifier = "cizgi.daily-review"

    static func update(enabled: Bool, hour: Int) async throws {
        #if canImport(UserNotifications)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        guard enabled else { return }
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw NotificationError.permissionDenied
        }
        let content = UNMutableNotificationContent()
        content.title = "Çizgi tekrar zamanı"
        content.body = "Bugün zamanı gelen kartlarını birkaç dakikada tamamla."
        content.sound = .default
        var components = DateComponents()
        components.hour = min(max(hour, 0), 23)
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try await center.add(request)
        #endif
    }

    enum NotificationError: LocalizedError {
        case permissionDenied
        var errorDescription: String? { "Bildirim izni verilmedi. Ayarlar uygulamasından izin verebilirsin." }
    }
}
