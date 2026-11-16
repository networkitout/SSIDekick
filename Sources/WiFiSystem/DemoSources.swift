import Foundation
import WiFiCore

/// Canned situations for trying the app without real Wi-Fi data. Demo sources never touch the network.
public enum DemoScenario: String, CaseIterable {
    case office, planeTwin, clonedAddress, newcomer, gatewayChange, locationDenied, wifiOff
}

public func demoSources(_ scenario: DemoScenario) -> (wifi: WiFiSource, config: NetworkConfigSource, neighbors: NeighborSource,
                                                      prober: Prober, location: LocationAuthorizing, vendors: VendorLookup) {
    let created = Date()
    let wifi: DemoWiFi
    switch scenario {
    case .office:
        wifi = DemoWiFi(connectedTo: Demo.corp[0], scan: Demo.corp + [Demo.home[0]])
    case .planeTwin:
        wifi = DemoWiFi(connectedTo: Demo.inflight[0], scan: Demo.inflight)
    case .clonedAddress:
        wifi = DemoWiFi(connectedTo: Demo.corp[1], scan: Demo.corp + [Demo.corpClone])
    case .newcomer:
        wifi = DemoWiFi(connectedTo: Demo.home[0], scan: Demo.home, created: created,
                        lateArrivals: (after: 10, entries: [Demo.homeNewcomer]))
    case .gatewayChange:
        wifi = DemoWiFi(connectedTo: Demo.home[0], scan: Demo.home)
    case .locationDenied:
        wifi = DemoWiFi(connectedTo: Demo.redacted(Demo.corp[0]), scan: Demo.corp.map(Demo.redacted))
    case .wifiOff:
        wifi = DemoWiFi(off: ())
    }

    let config: DemoConfig
    switch scenario {
    case .office, .clonedAddress, .locationDenied:
        config = DemoConfig(NetworkConfig(gatewayIP: "10.20.0.1", dnsServers: ["10.20.0.53"],
                                          ipv4: ["10.20.14.87"], ipv6: ["fd12:3456:789a::87"]))
    case .planeTwin:
        config = DemoConfig(NetworkConfig(gatewayIP: "172.19.0.1", dnsServers: ["172.19.0.1"],
                                          ipv4: ["172.19.3.112"], ipv6: []))
    case .newcomer, .gatewayChange:
        config = DemoConfig(NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["192.168.1.1"],
                                          ipv4: ["192.168.1.34"], ipv6: ["fd00::34"]))
    case .wifiOff:
        config = DemoConfig(NetworkConfig(gatewayIP: nil, dnsServers: [], ipv4: [], ipv6: []))
    }

    let neighbors: DemoNeighbors
    switch scenario {
    case .gatewayChange:
        neighbors = DemoNeighbors(answer: Demo.mac("00:14:6c:5e:a0:01"), created: created,
                                  laterAnswer: (after: 15, address: Demo.mac("50:c7:bf:91:3d:07")))
    case .wifiOff:
        neighbors = DemoNeighbors(answer: nil, created: created)
    default:
        neighbors = DemoNeighbors(answer: Demo.mac("00:14:6c:5e:a0:01"), created: created)
    }

    let prober = scenario == .wifiOff ? DemoProber(online: false) : DemoProber(online: true)
    let location = DemoLocation(authorized: scenario != .locationDenied)
    return (wifi, config, neighbors, prober, location, Demo.vendors)
}

// MARK: - Fixed data

private enum Demo {
    static func mac(_ s: String) -> MACAddress { MACAddress(s)! }

    static let vendors = VendorTable(tsv: """
    000B86\tAruba Networks
    F09FC2\tUbiquiti
    00146C\tNetgear
    50C7BF\tTP-Link
    """)

    static func ap(_ ssid: String, _ bssid: String, rssi: Int, channel: Int, band: Band = .ghz5, width: Int = 80,
                   security: Set<SecurityMode> = [.wpa2, .wpa3], generation: WiFiGeneration = .wifi6) -> AccessPoint {
        AccessPoint(ssid: ssid, bssid: mac(bssid), rssi: rssi, noise: -92,
                    channel: Channel(number: channel, band: band, widthMHz: width),
                    security: security, generation: generation, countryCode: "US", beaconInterval: 100)
    }

    static let corp = [
        ap("Corp", "00:0b:86:3a:10:01", rssi: -52, channel: 36),
        ap("Corp", "00:0b:86:3a:10:11", rssi: -64, channel: 149),
        ap("Corp", "00:0b:86:3a:22:01", rssi: -71, channel: 6, band: .ghz2_4, width: 20),
    ]
    /// Same address as `corp[0]`, heard on a second channel.
    static let corpClone = ap("Corp", "00:0b:86:3a:10:01", rssi: -48, channel: 44)

    static let inflight = [
        ap("InflightWiFi", "f0:9f:c2:71:04:a1", rssi: -55, channel: 36, security: [.open]),
        ap("InflightWiFi", "f0:9f:c2:71:04:b2", rssi: -63, channel: 149, security: [.open]),
        ap("InflightWiFi", "f0:9f:c2:71:05:c3", rssi: -70, channel: 44, security: [.open]),
        ap("InflightWiFi", "50:c7:bf:0e:88:14", rssi: -45, channel: 40, security: [.open]),
    ]

    static let home = [
        ap("Home", "00:14:6c:5e:a0:10", rssi: -58, channel: 100),
        ap("Home", "00:14:6c:5e:a0:20", rssi: -74, channel: 11, band: .ghz2_4, width: 20),
    ]
    /// Same vendor as the real `Home` access points, but new and louder.
    static let homeNewcomer = ap("Home", "00:14:6c:5e:b7:42", rssi: -38, channel: 104)

    /// What macOS reports without Location permission: no names, no addresses.
    static func redacted(_ entry: AccessPoint) -> AccessPoint {
        var copy = entry
        copy.ssid = nil
        copy.bssid = nil
        return copy
    }
}

// MARK: - Sources

private struct DemoWiFiOffError: LocalizedError {
    var errorDescription: String? { "Wi-Fi is turned off." }
}

private final class DemoWiFi: WiFiSource {
    private let link: LinkSnapshot?
    private let entries: [AccessPoint]
    private let created: Date
    private let lateArrivals: (after: TimeInterval, entries: [AccessPoint])?
    private let isOff: Bool

    init(connectedTo entry: AccessPoint, scan: [AccessPoint], created: Date = Date(),
         lateArrivals: (after: TimeInterval, entries: [AccessPoint])? = nil) {
        link = LinkSnapshot(ssid: entry.ssid, bssid: entry.bssid, rssi: entry.rssi, noise: entry.noise,
                            txRateMbps: 864, channel: entry.channel, generation: entry.generation,
                            security: entry.weakestSecurity, countryCode: entry.countryCode)
        entries = scan
        self.created = created
        self.lateArrivals = lateArrivals
        isOff = false
    }

    init(off: Void) {
        link = nil
        entries = []
        created = Date()
        lateArrivals = nil
        isOff = true
    }

    func state() -> WiFiState { isOff ? .off : .connected }
    func currentLink() -> LinkSnapshot? { link }
    func cachedScan() -> [AccessPoint] { entries }

    func scan() async throws -> [AccessPoint] {
        if isOff { throw DemoWiFiOffError() }
        if let lateArrivals, Date().timeIntervalSince(created) >= lateArrivals.after {
            return entries + lateArrivals.entries
        }
        return entries
    }

    /// Announces the join once, so a started Engine scans right away, as it would after joining a network.
    var events: AsyncStream<WiFiEvent> {
        let joined = !isOff
        return AsyncStream { continuation in
            if joined { continuation.yield(.ssidChanged) }
            continuation.finish()
        }
    }
}

private final class DemoConfig: NetworkConfigSource {
    private let config: NetworkConfig
    init(_ config: NetworkConfig) { self.config = config }
    func current() -> NetworkConfig { config }
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class DemoNeighbors: NeighborSource {
    private let answer: MACAddress?
    private let created: Date
    private let laterAnswer: (after: TimeInterval, address: MACAddress)?

    init(answer: MACAddress?, created: Date, laterAnswer: (after: TimeInterval, address: MACAddress)? = nil) {
        self.answer = answer
        self.created = created
        self.laterAnswer = laterAnswer
    }

    func hardwareAddress(forIPv4 ip: String) async -> MACAddress? {
        if let laterAnswer, Date().timeIntervalSince(created) >= laterAnswer.after { return laterAnswer.address }
        return answer
    }
}

private final class DemoProber: Prober {
    private let online: Bool
    init(online: Bool) { self.online = online }

    func ping(_ ip: String) async -> Double? { online ? 3.4 : nil }
    func dnsLatency(server: String) async -> Double? { online ? 18.2 : nil }
    func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) { online ? (.online, 41.7) : (.offline, nil) }
    /// An address from the documentation range (RFC 5737).
    func publicIP() async -> String? { online ? "203.0.113.24" : nil }
}

private final class DemoLocation: LocationAuthorizing {
    let isAuthorized: Bool
    let isDetermined = true
    init(authorized: Bool) { isAuthorized = authorized }
    func request() {}
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}
