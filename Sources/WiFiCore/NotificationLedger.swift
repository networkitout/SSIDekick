import Foundation

/// Decides which findings deserve a notification, once per connection session.
public struct NotificationLedger: Sendable {
    private var sessionID: Int?
    /// What makes two findings "the same" for notifying: reason text is left out, because sibling reasons embed
    /// counts that change from scan to scan.
    private struct Key: Hashable {
        var signal: Signal
        var ssid: String
        var bssid: MACAddress?
    }
    private var delivered: Set<Key> = []

    public init() {}

    /// Findings for `connectedSSID` whose access point (or the nil-address bucket) scores `.worthALook` or
    /// higher and that were not returned earlier in this `sessionID` (same signal, name and address), in the order
    /// they appear in `findings`. A new `sessionID` forgets everything.
    public mutating func pending(findings: [Finding], connectedSSID: String?, sessionID: Int) -> [Finding] {
        if self.sessionID != sessionID {
            self.sessionID = sessionID
            delivered = []
        }
        guard let connectedSSID else { return [] }
        let mine = findings.filter { $0.ssid == connectedSSID }
        var qualifies: [MACAddress?: Bool] = [:]
        var result: [Finding] = []
        for finding in mine {
            let address = finding.bssid
            let ok = qualifies[address] ?? (verdict(for: mine.filter { $0.bssid == address }) >= .worthALook)
            qualifies[address] = ok
            guard ok else { continue }
            let key = Key(signal: finding.signal, ssid: finding.ssid, bssid: address)
            if delivered.insert(key).inserted { result.append(finding) }
        }
        return result
    }
}
