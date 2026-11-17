import Foundation

/// The access points that share one network name (or one nameless entry), with the worst verdict among them.
public struct NetworkGroup: Sendable, Identifiable {
    /// The network name, or "hidden-<n>" for nameless entries.
    public var id: String
    public var ssid: String?
    /// Strongest first.
    public var accessPoints: [AccessPoint]
    public var verdict: Verdict
    public var isConnected: Bool

    public init(id: String, ssid: String?, accessPoints: [AccessPoint], verdict: Verdict, isConnected: Bool) {
        self.id = id
        self.ssid = ssid
        self.accessPoints = accessPoints
        self.verdict = verdict
        self.isConnected = isConnected
    }
}

/// The findings that belong to one access point's row: same name and same address.
/// Connection-level findings (no address) belong to the connected group's header, never to a row.
public func findings(for accessPoint: AccessPoint, in findings: [Finding]) -> [Finding] {
    guard let ssid = accessPoint.ssid, let bssid = accessPoint.bssid else { return [] }
    return findings.filter { $0.ssid == ssid && $0.bssid == bssid }
}

/// The connection-level findings of the connected network, shown once in its group header.
public func connectionFindings(ssid: String, in findings: [Finding]) -> [Finding] {
    findings.filter { $0.ssid == ssid && $0.bssid == nil }
}

/// Groups a scan by network name. Order: the connected group, then by verdict (worst first), then by strongest
/// signal. Each nameless entry is its own group, after all named ones.
public func groupScan(_ scan: [AccessPoint], findings: [Finding], connectedSSID: String?) -> [NetworkGroup] {
    var named: [String: [AccessPoint]] = [:]
    var nameless: [AccessPoint] = []
    for accessPoint in scan {
        if let ssid = accessPoint.ssid, !ssid.isEmpty {
            named[ssid, default: []].append(accessPoint)
        } else {
            nameless.append(accessPoint)
        }
    }

    let namedGroups: [NetworkGroup] = named.map { ssid, members in
        let sorted = members.sorted { $0.rssi > $1.rssi }
        let isConnected = ssid == connectedSSID
        var verdicts = sorted.map { verdict(for: WiFiCore.findings(for: $0, in: findings)) }
        if isConnected { verdicts.append(verdict(for: connectionFindings(ssid: ssid, in: findings))) }
        return NetworkGroup(id: ssid, ssid: ssid, accessPoints: sorted, verdict: verdicts.max() ?? .clear,
                            isConnected: isConnected)
    }
    .sorted { a, b in
        if a.isConnected != b.isConnected { return a.isConnected }
        if a.verdict != b.verdict { return a.verdict > b.verdict }
        let (x, y) = (a.accessPoints[0].rssi, b.accessPoints[0].rssi)
        if x != y { return x > y }
        return a.id < b.id
    }

    let hiddenGroups = nameless.sorted { $0.rssi > $1.rssi }.enumerated().map { index, accessPoint in
        NetworkGroup(id: "hidden-\(index)", ssid: nil, accessPoints: [accessPoint], verdict: .clear,
                     isConnected: false)
    }
    return namedGroups + hiddenGroups
}

/// "Scanned 12 s ago" and friends for the scan window's header.
public func scanAgeText(scanTime: Date?, now: Date) -> String {
    guard let scanTime else { return "Not scanned yet" }
    let seconds = Int(now.timeIntervalSince(scanTime))
    if seconds < 1 { return "Scanned just now" }
    if seconds < 60 { return "Scanned \(seconds) s ago" }
    if seconds < 3600 { return "Scanned \(seconds / 60) min ago" }
    return "Scanned \(seconds / 3600) h ago"
}

/// Bar opacity for a channel: linear from 0.25 at -90 dBm or weaker to 1.0 at -40 dBm or stronger.
public func signalOpacity(rssi: Int) -> Double {
    let fraction = min(1, max(0, Double(rssi + 90) / 50))
    return 0.25 + 0.75 * fraction
}
