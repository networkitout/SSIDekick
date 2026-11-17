import Foundation
import UserNotifications
import WiFiCore

/// Posts one notification per finding. Permission is requested the first time a finding needs it, off the main
/// actor's critical path; if it is denied this does nothing (the icon colour still changes).
/// It is also the notification centre's delegate, so banners show while a WiFiUtil window is frontmost.
/// Outside an app bundle (`swift run`) it does nothing: the notification centre traps there.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let isBundled = Bundle.main.bundleIdentifier != nil

    override init() {
        super.init()
        // Setting the delegate asks for no permission.
        if isBundled { UNUserNotificationCenter.current().delegate = self }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func post(_ findings: [Finding]) {
        guard isBundled, !findings.isEmpty else { return }
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
