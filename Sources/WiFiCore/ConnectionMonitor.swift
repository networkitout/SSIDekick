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
    /// How long the gateway and DNS baselines may still move after their value is first seen in a session.
    public static let settleSeconds: TimeInterval = 10
    /// How many completed scans make up the newcomer baseline; newcomer checks start with the scan after them.
    public static let newcomerBaselineScans = 3

    /// Increments each time a new session starts.
    public private(set) var sessionID: Int = 0

    private var ssid: String?
    private var lastBSSID: MACAddress?
    private var gatewayBaseline: MACAddress?
    private var gatewayFirstSeen: Date?
    private var dnsBaseline: Set<String>?
    private var dnsFirstSeen: Date?
    private var newcomerBaseline = NewcomerBaseline()
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

    /// Ends the current session, if any; the next connection starts a new one even under the same name.
    public mutating func reset() {
        endSession()
    }

    private mutating func endSession() {
        ssid = nil
        lastBSSID = nil
        gatewayBaseline = nil
        gatewayFirstSeen = nil
        dnsBaseline = nil
        dnsFirstSeen = nil
        newcomerBaseline = NewcomerBaseline()
        findings = []
    }

    private mutating func raise(_ finding: Finding) {
        if !findings.contains(where: { $0.signal == finding.signal && $0.bssid == finding.bssid }) {
            findings.append(finding)
        }
    }

    /// The gateway baseline follows the latest value for `settleSeconds` after the first value seen this session,
    /// so a router address read before DHCP finished never counts as a change.
    private mutating func checkGateway(_ gateway: MACAddress?, name: String, now: Date) {
        guard let gateway else { return }
        guard let baseline = gatewayBaseline, let firstSeen = gatewayFirstSeen else {
            gatewayBaseline = gateway
            gatewayFirstSeen = now
            return
        }
        if now <= firstSeen + Self.settleSeconds {
            gatewayBaseline = gateway
        } else if gateway != baseline {
            raise(Finding(signal: .gatewayChanged, ssid: name, bssid: nil,
                          reason: "The router's hardware address changed during this connection (\(baseline) to \(gateway))."))
        }
    }

    /// Like the gateway, the DNS baseline settles `settleSeconds` after the first non-empty set seen this session.
    private mutating func checkDNS(_ servers: [String], name: String, now: Date) {
        let current = Set(servers)
        guard !current.isEmpty else { return }
        guard let baseline = dnsBaseline, let firstSeen = dnsFirstSeen else {
            dnsBaseline = current
            dnsFirstSeen = now
            return
        }
        if now <= firstSeen + Self.settleSeconds {
            dnsBaseline = current
        } else if current != baseline {
            raise(Finding(signal: .dnsChanged, ssid: name, bssid: nil,
                          reason: "The DNS servers changed after the connection settled."))
        }
    }

    /// The first `newcomerBaselineScans` scans of a session build the baseline (one scan often misses an access
    /// point). After that, a same-name address outside the baseline that is louder than the connected one is a
    /// newcomer, unless it shares a maker prefix with a baseline address and its security is no weaker than the
    /// weakest baseline security.
    private mutating func checkScan(_ scan: [AccessPoint], connection: ConnectionState) {
        let sameName = scan.filter { $0.ssid == connection.ssid && $0.bssid != nil }
        guard newcomerBaseline.scans >= Self.newcomerBaselineScans else {
            newcomerBaseline.add(sameName)
            return
        }
        for candidate in sameName {
            guard let address = candidate.bssid, !newcomerBaseline.addresses.contains(address),
                  candidate.rssi > connection.rssi,
                  !newcomerBaseline.isSameMaker(candidate) else { continue }
            raise(Finding(signal: .louderNewcomer, ssid: connection.ssid, bssid: address,
                          reason: "A new access point with this network name appeared and is louder than the one you are using."))
        }
    }

    /// A move counts only when the destination already scores worth a look or higher on its own findings.
    private mutating func checkMove(to address: MACAddress, name: String, siblingFindings: [Finding]) {
        let destination = siblingFindings.filter { $0.bssid == address }
            + findings.filter { $0.signal == .louderNewcomer && $0.bssid == address }
        if verdict(for: destination) >= .worthALook {
            raise(Finding(signal: .movedToFlagged, ssid: name, bssid: address,
                          reason: "You moved onto an access point already flagged as worth a look or suspect."))
        }
    }
}

/// The same-name access points seen in a session's first scans.
private struct NewcomerBaseline: Sendable {
    var scans = 0
    var addresses: Set<MACAddress> = []
    /// Maker prefixes with the locally-administered bit cleared.
    var ouis: Set<UInt32> = []
    var weakestSecurity: SecurityMode?

    mutating func add(_ entries: [AccessPoint]) {
        scans += 1
        for entry in entries {
            guard let address = entry.bssid else { continue }
            addresses.insert(address)
            ouis.insert(Self.maker(address))
            weakestSecurity = min(weakestSecurity ?? entry.weakestSecurity, entry.weakestSecurity)
        }
    }

    func isSameMaker(_ candidate: AccessPoint) -> Bool {
        guard let address = candidate.bssid, let weakestSecurity else { return false }
        return ouis.contains(Self.maker(address)) && candidate.weakestSecurity >= weakestSecurity
    }

    static func maker(_ address: MACAddress) -> UInt32 { address.oui & ~0x020000 }
}
