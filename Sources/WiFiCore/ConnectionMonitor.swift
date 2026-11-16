import Foundation

public struct ConnectionState: Sendable, Hashable {
    public var ssid: String
    public var bssid: MACAddress
    public var rssi: Int
    public var gatewayMAC: MACAddress?
    public var dnsServers: [String]

    public init(ssid: String, bssid: MACAddress, rssi: Int, gatewayMAC: MACAddress?, dnsServers: [String]) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.gatewayMAC = gatewayMAC
        self.dnsServers = dnsServers
    }
}

/// Watches one connected session (continuous association with one network name) for signs of an evil twin.
public struct ConnectionMonitor: Sendable {
    public static let settleSeconds: TimeInterval = 10

    /// Increments each time a new session starts.
    public private(set) var sessionID: Int = 0

    private var ssid: String?
    private var startedAt = Date.distantPast
    private var lastBSSID: MACAddress?
    private var gatewayBaseline: MACAddress?
    private var dnsBaseline: Set<String>?
    private var newcomerBaseline: Set<MACAddress>?
    private var findings: [Finding] = []

    public init() {}

    /// scan: pass a scan only when a new full scan has completed since the last call, else nil.
    public mutating func update(connection: ConnectionState?, scan: [AccessPoint]?,
                                siblingFindings: [Finding], now: Date) -> [Finding] {
        guard let connection else {
            endSession()
            return []
        }
        if connection.ssid != ssid {
            endSession()
            ssid = connection.ssid
            startedAt = now
            sessionID += 1
        }
        let name = connection.ssid

        checkGateway(connection.gatewayMAC, name: name, now: now)
        checkDNS(connection.dnsServers, name: name, now: now)
        if let scan { checkScan(scan, connection: connection) }
        if let previous = lastBSSID, previous != connection.bssid {
            checkMove(to: connection.bssid, name: name, siblingFindings: siblingFindings)
        }
        lastBSSID = connection.bssid
        return findings
    }

    private mutating func endSession() {
        ssid = nil
        lastBSSID = nil
        gatewayBaseline = nil
        dnsBaseline = nil
        newcomerBaseline = nil
        findings = []
    }

    private mutating func raise(_ finding: Finding) {
        if !findings.contains(where: { $0.signal == finding.signal && $0.bssid == finding.bssid }) {
            findings.append(finding)
        }
    }

    /// Like DNS, the gateway baseline follows the latest value until the session settles, so a router address
    /// read before DHCP finished never counts as a change.
    private mutating func checkGateway(_ gateway: MACAddress?, name: String, now: Date) {
        guard let gateway else { return }
        guard let baseline = gatewayBaseline else {
            gatewayBaseline = gateway
            return
        }
        if now <= startedAt + Self.settleSeconds {
            gatewayBaseline = gateway
        } else if gateway != baseline {
            raise(Finding(signal: .gatewayChanged, ssid: name, bssid: nil,
                          reason: "The router's hardware address changed during this connection (\(baseline) to \(gateway))."))
        }
    }

    private mutating func checkDNS(_ servers: [String], name: String, now: Date) {
        let current = Set(servers)
        guard !current.isEmpty else { return }
        guard let baseline = dnsBaseline else {
            dnsBaseline = current
            return
        }
        if now <= startedAt + Self.settleSeconds {
            dnsBaseline = current
        } else if current != baseline {
            raise(Finding(signal: .dnsChanged, ssid: name, bssid: nil,
                          reason: "The DNS servers changed after the connection settled."))
        }
    }

    private mutating func checkScan(_ scan: [AccessPoint], connection: ConnectionState) {
        let sameName = scan.filter { $0.ssid == connection.ssid && $0.bssid != nil }
        guard let baseline = newcomerBaseline else {
            newcomerBaseline = Set(sameName.compactMap(\.bssid))
            return
        }
        for candidate in sameName {
            guard let address = candidate.bssid, !baseline.contains(address),
                  candidate.rssi > connection.rssi else { continue }
            raise(Finding(signal: .louderNewcomer, ssid: connection.ssid, bssid: address,
                          reason: "A new access point with this network name appeared and is louder than the one you are using."))
        }
    }

    private mutating func checkMove(to address: MACAddress, name: String, siblingFindings: [Finding]) {
        let flagged = siblingFindings.contains { $0.bssid == address }
            || findings.contains { $0.signal == .louderNewcomer && $0.bssid == address }
        if flagged {
            raise(Finding(signal: .movedToFlagged, ssid: name, bssid: address,
                          reason: "You moved onto an access point that was already flagged as worth a look."))
        }
    }
}
