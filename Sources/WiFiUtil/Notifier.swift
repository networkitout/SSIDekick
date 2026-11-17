import Foundation
import UserNotifications
import WiFiCore

/// Posts one notification per finding. Permission is requested the first time a finding needs it, off the main
/// actor's critical path; if it is denied this does nothing (the icon colour still changes).
@MainActor
final class Notifier {
    func post(_ findings: [Finding]) {
        guard !findings.isEmpty else { return }
        let contents = findings.map(notificationContent(for:))
        Task {
            let center = UNUserNotificationCenter.current()
            guard await Self.isAllowed(center) else { return }
            for content in contents {
                let request = UNMutableNotificationContent()
                request.title = content.title
                request.body = content.body
                // The same identifier replaces a pending or delivered notification instead of adding a second.
                try? await center.add(UNNotificationRequest(identifier: content.identifier, content: request, trigger: nil))
            }
        }
    }

    private static func isAllowed(_ center: UNUserNotificationCenter) async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default: return false
        }
    }
}
