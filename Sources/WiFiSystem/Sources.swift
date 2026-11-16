import Foundation
import WiFiCore

/// Something about the Wi-Fi interface changed.
public enum WiFiEvent: Sendable { case powerChanged, ssidChanged, bssidChanged, linkChanged }

/// The Wi-Fi interface: power state, current link and scans.
public protocol WiFiSource: AnyObject {
    func state() -> WiFiState
    func currentLink() -> LinkSnapshot?
    /// The last scan results the system already holds; never triggers a scan.
    func cachedScan() -> [AccessPoint]
    /// Runs a full scan.
    func scan() async throws -> [AccessPoint]
    var events: AsyncStream<WiFiEvent> { get }
}

public struct NetworkConfig: Sendable, Hashable {
    public var gatewayIP: String?
    public var dnsServers: [String]
    public var ipv4: [String]
    public var ipv6: [String]

    public init(gatewayIP: String?, dnsServers: [String], ipv4: [String], ipv6: [String]) {
        self.gatewayIP = gatewayIP
        self.dnsServers = dnsServers
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }
}

/// The IP configuration of the Wi-Fi interface.
public protocol NetworkConfigSource: AnyObject {
    func current() -> NetworkConfig
    var changes: AsyncStream<Void> { get }
}

/// Resolves a neighbour's hardware address (ARP).
public protocol NeighborSource: AnyObject {
    func hardwareAddress(forIPv4 ip: String) async -> MACAddress?
}

/// Network probes. Latencies are in milliseconds; nil means the probe failed.
public protocol Prober: AnyObject {
    func ping(_ ip: String) async -> Double?
    func dnsLatency(server: String) async -> Double?
    func internetCheck() async -> (status: InternetStatus, latencyMs: Double?)
    func publicIP() async -> String?
}

/// Location Services authorisation, which macOS requires before it reveals network names and addresses.
public protocol LocationAuthorizing: AnyObject {
    var isAuthorized: Bool { get }
    var isDetermined: Bool { get }
    func request()
    var changes: AsyncStream<Void> { get }
}
