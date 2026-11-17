import Foundation

/// What one notification says. `identifier` is stable per finding so the system never shows a duplicate.
public struct NotificationContent: Sendable, Equatable {
    public var identifier: String
    public var title: String
    public var body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

public func notificationContent(for finding: Finding) -> NotificationContent {
    let title = finding.signal.strength == .strong
        ? "Suspect twin: \(finding.ssid)"
        : "Worth a look: \(finding.ssid)"
    let identifier = "finding.\(finding.signal.rawValue).\(finding.ssid).\(finding.bssid?.description ?? "-")"
    return NotificationContent(identifier: identifier, title: title, body: finding.reason)
}
