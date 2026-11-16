import Foundation

/// Decides which findings deserve a notification, once per connection session.
public struct NotificationLedger: Sendable {
    private var sessionID: Int?
    private var delivered: Set<Finding> = []

    public init() {}

    /// Findings for `connectedSSID` whose access point (or the nil-address bucket) scores `.worthALook` or
    /// higher and that were not returned earlier in this `sessionID`. A new `sessionID` forgets everything.
    public mutating func pending(findings: [Finding], connectedSSID: String?, sessionID: Int) -> [Finding] {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            delivered = []
        }
        guard let connectedSSID else { return [] }
        let mine = findings.filter { $0.ssid == connectedSSID }
        var result: [Finding] = []
        for address in Set(mine.map(\.bssid)) {
            let bucket = mine.filter { $0.bssid == address }
            guard verdict(for: bucket) >= .worthALook else { continue }
            for finding in bucket where delivered.insert(finding).inserted { result.append(finding) }
        }
        return result
    }
}
