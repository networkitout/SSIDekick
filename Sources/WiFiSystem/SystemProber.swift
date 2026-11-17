import Foundation
import WiFiCore

/// The real network probes: ICMP ping, a UDP DNS query, the captive check and the public-IP lookup.
/// The ping and DNS sockets are bound to the Wi-Fi interface. The two HTTP probes follow the system's default route
/// (v1 ruling).
public final class SystemProber: Prober {
    private let http = HTTPProbes()
    private let interfaceName: String

    public init(interfaceName: String) {
        self.interfaceName = interfaceName
    }

    public func ping(_ ip: String) async -> PingResult {
        await icmpPing(ip, interface: interfaceName, timeout: 1)
    }

    public func dnsLatency(server: String) async -> PingResult {
        await dnsProbe(server: server, interface: interfaceName, timeout: 2)
    }

    public func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) {
        await http.captiveCheck()
    }

    public func publicIP() async -> String? {
        await http.publicIP()
    }
}
