import Foundation
import WiFiCore

/// The real network probes: ICMP ping, a UDP DNS query, the captive check and the public-IP lookup.
public final class SystemProber: Prober {
    private let http = HTTPProbes()

    public init() {}

    public func ping(_ ip: String) async -> Double? {
        await icmpPing(ip, timeout: 1)
    }

    public func dnsLatency(server: String) async -> Double? {
        await dnsProbe(server: server, timeout: 2)
    }

    public func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) {
        await http.captiveCheck()
    }

    public func publicIP() async -> String? {
        await http.publicIP()
    }
}
