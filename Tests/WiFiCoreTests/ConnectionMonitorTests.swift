import Testing
import Foundation
@testable import WiFiCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func mac(_ s: String) -> MACAddress { MACAddress(s)! }
private let X = mac("aa:bb:cc:00:00:01")
private let Y = mac("aa:bb:cc:00:00:02")

private func conn(_ ssid: String = "Home", _ bssid: MACAddress = X, rssi: Int = -60,
                  gw: String? = nil, dns: [String] = []) -> ConnectionState {
    ConnectionState(ssid: ssid, bssid: bssid, rssi: rssi, gatewayMAC: gw.flatMap { MACAddress($0) }, dnsServers: dns)
}

struct ConnectionMonitorTests {
    @Test func plainRoamIsSilent() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("Home", X), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn("Home", Y), scan: nil, siblingFindings: [], now: t0 + 5)
        #expect(out.isEmpty)
    }

    @Test func gatewayChange() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 5)
        #expect(out.map(\.signal) == [.gatewayChanged])
        #expect(out[0].bssid == nil)
        #expect(out[0].ssid == "Home")
    }

    @Test func gatewayNilThenValueIsSilent() {
        var m = ConnectionMonitor()
        var out: [Finding] = []
        for (i, gw) in [nil, "00:11:22:33:44:01", nil, "00:11:22:33:44:01"].enumerated() {
            out = m.update(connection: conn(gw: gw), scan: nil, siblingFindings: [], now: t0 + Double(i))
        }
        #expect(out.isEmpty)
    }

    @Test func dnsLateArrivalIsSilent() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(dns: ["10.0.0.1", "fe80::1"]), scan: nil, siblingFindings: [], now: t0 + 3)
        let out = m.update(connection: conn(dns: ["10.0.0.1", "fe80::1"]), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.isEmpty)
    }

    @Test func dnsChangeAfterSettle() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn(dns: ["6.6.6.6"]), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.map(\.signal) == [.dnsChanged])
        #expect(out[0].bssid == nil)
    }

    @Test func dnsOrderAndEmptyAreIgnored() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(dns: ["10.0.0.1", "10.0.0.2"]), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(dns: []), scan: nil, siblingFindings: [], now: t0 + 20)
        let out = m.update(connection: conn(dns: ["10.0.0.2", "10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.isEmpty)
    }

    @Test func dnsFirstSeenAfterSettleBecomesBaselineSilently() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(dns: []), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 20)
        let out = m.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 40)
        #expect(out.isEmpty)
    }

    @Test func reconnectResetsBaselines() {
        var m = ConnectionMonitor()
        let before = m.sessionID
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        #expect(m.sessionID == before + 1)
        _ = m.update(connection: nil, scan: nil, siblingFindings: [], now: t0 + 1)
        let out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 2)
        #expect(out.isEmpty)
        #expect(m.sessionID == before + 2)
    }

    @Test func renameResetsBaselines() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("A", gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn("B", gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 1)
        #expect(out.isEmpty)
    }

    @Test func louderNewcomer() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(), scan: [ap("Home", X.description, rssi: -60)], siblingFindings: [], now: t0)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description, rssi: -60), ap("Home", Y.description, rssi: -45)],
                           siblingFindings: [], now: t0 + 60)
        #expect(out.map(\.signal) == [.louderNewcomer])
        #expect(out[0].bssid == Y)
    }

    @Test func quieterNewcomerIsSilent() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(), scan: [ap("Home", X.description, rssi: -60)], siblingFindings: [], now: t0)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Home", Y.description, rssi: -75)],
                           siblingFindings: [], now: t0 + 60)
        #expect(out.isEmpty)
    }

    @Test func otherNamesAndHiddenAddressesAreNotNewcomers() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(), scan: [ap("Home", X.description)], siblingFindings: [], now: t0)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Other", Y.description, rssi: -30),
                                                      ap("Home", nil, rssi: -30)], siblingFindings: [], now: t0 + 60)
        #expect(out.isEmpty)
    }

    @Test func presentAtFirstScanIsNotNewcomer() {
        var m = ConnectionMonitor()
        let scan = [ap("Home", X.description, rssi: -60), ap("Home", Y.description, rssi: -45)]
        _ = m.update(connection: conn(), scan: scan, siblingFindings: [], now: t0)
        let out = m.update(connection: conn(), scan: scan, siblingFindings: [], now: t0 + 60)
        #expect(out.isEmpty)
    }

    @Test func movedToFlagged() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("Home", X), scan: nil, siblingFindings: [], now: t0)
        let sibling = Finding(signal: .vendorMismatch, ssid: "Home", bssid: Y, reason: "different maker")
        let out = m.update(connection: conn("Home", Y), scan: nil, siblingFindings: [sibling], now: t0 + 5)
        #expect(out.map(\.signal) == [.movedToFlagged])
        #expect(out[0].bssid == Y)
    }

    @Test func movedToLouderNewcomer() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("Home", X), scan: [ap("Home", X.description)], siblingFindings: [], now: t0)
        _ = m.update(connection: conn("Home", X), scan: [ap("Home", X.description), ap("Home", Y.description, rssi: -40)],
                     siblingFindings: [], now: t0 + 60)
        let out = m.update(connection: conn("Home", Y, rssi: -40), scan: nil, siblingFindings: [], now: t0 + 70)
        #expect(Set(out.map(\.signal)) == [.louderNewcomer, .movedToFlagged])
    }

    @Test func findingsPersistWithinSession() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 5)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 6)
        let out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 7)
        #expect(out.filter { $0.signal == .gatewayChanged }.count == 1)
    }
}
