import Foundation
import WiFiCore

/// The real network probes: ICMP ping, UDP DNS queries, the captive check, the public-IP lookup and the HTTPS trust
/// check. The ping and DNS sockets are bound to the Wi-Fi interface. The HTTP and HTTPS probes follow the system's
/// default route (v1 ruling).
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

    public func dnsLookup(name: String, server: String) async -> DNSLookup {
        await WiFiSystem.dnsLookup(name: name, server: server, interface: interfaceName, timeout: 2)
    }

    public func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) {
        await http.captiveCheck()
    }

    public func publicIP() async -> String? {
        await http.publicIP()
    }

    public func httpsCheck() async -> HTTPSState {
        await WiFiSystem.httpsCheck(url: URL(string: InterceptionCheck.httpsURL)!, timeout: 5)
    }
}
