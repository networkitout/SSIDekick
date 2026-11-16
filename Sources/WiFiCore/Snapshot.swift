import Foundation

public enum WiFiState: Sendable { case off, notConnected, connected }
public enum InternetStatus: Sendable { case unknown, online, captivePortal, offline }

public struct ConnectivitySnapshot: Sendable, Hashable {
    public var gatewayIP: String?
    public var gatewayMAC: MACAddress?
    public var gatewayLatencyMs: Double?
    public var gatewayLossPercent: Int?
    public var dnsServers: [String]
    public var dnsLatencyMs: Double?
    public var internet: InternetStatus
    public var internetLatencyMs: Double?
    public var ipv4: [String]
    public var ipv6: [String]
    public var publicIP: String?

    public init() {
        gatewayIP = nil
        gatewayMAC = nil
        gatewayLatencyMs = nil
        gatewayLossPercent = nil
        dnsServers = []
        dnsLatencyMs = nil
        internet = .unknown
        internetLatencyMs = nil
        ipv4 = []
        ipv6 = []
        publicIP = nil
    }
}

public struct Snapshot: Sendable {
    public var state: WiFiState
    public var locationAuthorized: Bool
    public var link: LinkSnapshot?
    public var connectivity: ConnectivitySnapshot
    public var scan: [AccessPoint]
    public var scanTime: Date?
    public var scanError: String?
    /// Sibling findings for all groups plus connected-session findings.
    public var findings: [Finding]
    /// `networkVerdict` for `link.ssid`; `.clear` when not connected.
    public var connectedVerdict: Verdict

    public init(state: WiFiState, locationAuthorized: Bool, link: LinkSnapshot?, connectivity: ConnectivitySnapshot,
                scan: [AccessPoint], scanTime: Date?, scanError: String?, findings: [Finding],
                connectedVerdict: Verdict) {
        self.state = state
        self.locationAuthorized = locationAuthorized
        self.link = link
        self.connectivity = connectivity
        self.scan = scan
        self.scanTime = scanTime
        self.scanError = scanError
        self.findings = findings
        self.connectedVerdict = connectedVerdict
    }

    public static let empty = Snapshot(state: .notConnected, locationAuthorized: false, link: nil,
                                       connectivity: ConnectivitySnapshot(), scan: [], scanTime: nil,
                                       scanError: nil, findings: [], connectedVerdict: .clear)
}

/// Rolling window of probe outcomes.
public struct LossWindow: Sendable {
    private let capacity: Int
    private var outcomes: [Bool] = []

    public init(capacity: Int = 20) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(success: Bool) {
        outcomes.append(success)
        if outcomes.count > capacity { outcomes.removeFirst(outcomes.count - capacity) }
    }

    /// Whole percent of failed probes; nil until one probe is recorded.
    public var lossPercent: Int? {
        guard !outcomes.isEmpty else { return nil }
        let failed = outcomes.filter { !$0 }.count
        return Int((Double(failed) * 100 / Double(outcomes.count)).rounded())
    }
}

public enum Cadence {
    public static func linkInterval(menuOpen: Bool) -> TimeInterval { menuOpen ? 1 : 10 }
    public static func probeInterval(menuOpen: Bool) -> TimeInterval { menuOpen ? 5 : 30 }
}
