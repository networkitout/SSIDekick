import Testing
import Foundation
@testable import WiFiCore

private let t0 = Date(timeIntervalSince1970: 1_000_000)
private func mac(_ s: String) -> MACAddress { MACAddress(s)! }
private let X = mac("aa:bb:cc:00:00:01")
private let Y = mac("aa:bb:cc:00:00:02")
/// A different maker's address (different OUI from X and Y).
private let Z = mac("00:22:33:00:00:09")

/// Feeds the three scans that make up the newcomer baseline; newcomer checks start with the next scan.
private func baseline(_ m: inout ConnectionMonitor, _ scans: [[AccessPoint]] = [[ap("Home", X.description)]],
                      connection: ConnectionState = conn()) {
    let three = scans.count >= 3 ? scans : scans + Array(repeating: scans.last!, count: 3 - scans.count)
    for (i, scan) in three.enumerated() {
        _ = m.update(connection: connection, scan: scan, siblingFindings: [], now: t0 + Double(i * 60))
    }
}
private let t4 = t0 + 240

private func conn(_ ssid: String = "Home", _ bssid: MACAddress = X, rssi: Int = -60,
                  gw: String? = nil, dns: [String] = [], answers: DNSAnswersState = .notChecked) -> ConnectionState {
    ConnectionState(ssid: ssid, bssid: bssid, rssi: rssi, gatewayMAC: gw.flatMap { MACAddress($0) }, dnsServers: dns,
                    dnsAnswers: answers)
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
        let out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.map(\.signal) == [.gatewayChanged])
        #expect(out[0].bssid == nil)
        #expect(out[0].ssid == "Home")
    }

    @Test func gatewayChangeInsideSettleIsSilent() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 5)
        _ = m.update(connection: conn(gw: nil), scan: nil, siblingFindings: [], now: t0 + 20)
        var out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.isEmpty)
        // The baseline moved to the value seen last inside the window.
        out = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 40)
        #expect(out.map(\.signal) == [.gatewayChanged])
    }

    @Test func gatewayFirstSeenAfterSettleBecomesBaselineSilently() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: nil), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 20)
        var out = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 40)
        #expect(out.isEmpty)
        // The late value is the baseline: a change from it raises, naming it.
        out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 50)
        #expect(out.map(\.signal) == [.gatewayChanged])
        #expect(out.first?.reason.contains("00:11:22:33:44:01 to 00:11:22:33:44:02") == true)
    }

    @Test func gatewaySettleCountsFromFirstObservation() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: nil), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 12)
        var out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 15)
        #expect(out.isEmpty)
        out = m.update(connection: conn(gw: "00:11:22:33:44:03"), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.map(\.signal) == [.gatewayChanged])
    }

    @Test func gatewaySettleBoundary() {
        var inside = ConnectionMonitor()
        _ = inside.update(connection: conn(gw: nil), scan: nil, siblingFindings: [], now: t0)
        _ = inside.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 5)
        #expect(inside.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 15).isEmpty)
        var after = ConnectionMonitor()
        _ = after.update(connection: conn(gw: nil), scan: nil, siblingFindings: [], now: t0)
        _ = after.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0 + 5)
        let out = after.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 15.001)
        #expect(out.map(\.signal) == [.gatewayChanged])
    }

    @Test func dnsSettleCountsFromFirstObservation() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(dns: []), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 12)
        var out = m.update(connection: conn(dns: ["10.0.0.1", "fe80::1"]), scan: nil, siblingFindings: [], now: t0 + 15)
        #expect(out.isEmpty)
        out = m.update(connection: conn(dns: ["10.0.0.1", "fe80::1"]), scan: nil, siblingFindings: [], now: t0 + 25)
        #expect(out.isEmpty)
        out = m.update(connection: conn(dns: ["6.6.6.6"]), scan: nil, siblingFindings: [], now: t0 + 30)
        #expect(out.map(\.signal) == [.dnsChanged])
    }

    @Test func dnsSettleBoundary() {
        var inside = ConnectionMonitor()
        _ = inside.update(connection: conn(dns: []), scan: nil, siblingFindings: [], now: t0)
        _ = inside.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 5)
        #expect(inside.update(connection: conn(dns: ["10.0.0.2"]), scan: nil, siblingFindings: [], now: t0 + 15).isEmpty)
        var after = ConnectionMonitor()
        _ = after.update(connection: conn(dns: []), scan: nil, siblingFindings: [], now: t0)
        _ = after.update(connection: conn(dns: ["10.0.0.1"]), scan: nil, siblingFindings: [], now: t0 + 5)
        let out = after.update(connection: conn(dns: ["10.0.0.2"]), scan: nil, siblingFindings: [], now: t0 + 15.001)
        #expect(out.map(\.signal) == [.dnsChanged])
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
        baseline(&m)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Home", Z.description, rssi: -45)],
                           siblingFindings: [], now: t4)
        #expect(out.map(\.signal) == [.louderNewcomer])
        #expect(out[0].bssid == Z)
    }

    @Test func noNewcomerChecksBeforeFourthScan() {
        var m = ConnectionMonitor()
        var out: [Finding] = []
        for (i, scan) in [[ap("Home", X.description)],
                          [ap("Home", X.description), ap("Home", Z.description, rssi: -45)],
                          [ap("Home", X.description)]].enumerated() {
            out = m.update(connection: conn(), scan: scan, siblingFindings: [], now: t0 + Double(i * 60))
            #expect(out.isEmpty)
        }
        // Seen in scan 2, so part of the baseline; scan 4 stays silent.
        out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Home", Z.description, rssi: -45)],
                       siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func sameMakerNewcomerIsSilent() {
        var m = ConnectionMonitor()
        baseline(&m)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Home", Y.description, rssi: -45)],
                           siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func sameMakerIgnoresLocallyAdministeredBit() {
        var m = ConnectionMonitor()
        let real = mac("a8:bb:cc:00:00:01"), software = mac("aa:bb:cc:00:00:07")
        baseline(&m, [[ap("Home", real.description)]], connection: conn("Home", real))
        let out = m.update(connection: conn("Home", real),
                           scan: [ap("Home", real.description), ap("Home", software.description, rssi: -45)],
                           siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func sameMakerButWeakerSecurityIsNewcomer() {
        var m = ConnectionMonitor()
        baseline(&m)
        let out = m.update(connection: conn(),
                           scan: [ap("Home", X.description), ap("Home", Y.description, rssi: -45, sec: [.open])],
                           siblingFindings: [], now: t4)
        #expect(out.map(\.signal) == [.louderNewcomer])
        #expect(out.first?.bssid == Y)
    }

    @Test func equallyLoudNewcomerIsSilent() {
        var m = ConnectionMonitor()
        baseline(&m)
        let out = m.update(connection: conn(rssi: -60),
                           scan: [ap("Home", X.description), ap("Home", Z.description, rssi: -60)],
                           siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func quieterNewcomerIsSilent() {
        var m = ConnectionMonitor()
        baseline(&m)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Home", Z.description, rssi: -75)],
                           siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func otherNamesAndHiddenAddressesAreNotNewcomers() {
        var m = ConnectionMonitor()
        baseline(&m)
        let out = m.update(connection: conn(), scan: [ap("Home", X.description), ap("Other", Z.description, rssi: -30),
                                                      ap("Home", nil, rssi: -30)], siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func presentAtFirstScanIsNotNewcomer() {
        var m = ConnectionMonitor()
        let scan = [ap("Home", X.description, rssi: -60), ap("Home", Z.description, rssi: -45)]
        baseline(&m, [scan])
        let out = m.update(connection: conn(), scan: scan, siblingFindings: [], now: t4)
        #expect(out.isEmpty)
    }

    @Test func movedToFlagged() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("Home", X), scan: nil, siblingFindings: [], now: t0)
        let sibling = Finding(signal: .vendorMismatch, ssid: "Home", bssid: Y, reason: "different maker")
        let out = m.update(connection: conn("Home", Y), scan: nil, siblingFindings: [sibling], now: t0 + 5)
        #expect(out.map(\.signal) == [.movedToFlagged])
        #expect(out[0].bssid == Y)
        #expect(out[0].reason == "You moved onto an access point already flagged as worth a look or suspect.")
    }

    @Test func roamOntoNoteLevelAccessPointIsSilent() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn("Home", X), scan: nil, siblingFindings: [], now: t0)
        let note = Finding(signal: .locallyAdministered, ssid: "Home", bssid: Y, reason: "software address")
        let out = m.update(connection: conn("Home", Y), scan: nil, siblingFindings: [note], now: t0 + 5)
        #expect(out.isEmpty)
    }

    @Test func movedToLouderNewcomer() {
        var m = ConnectionMonitor()
        baseline(&m)
        _ = m.update(connection: conn("Home", X), scan: [ap("Home", X.description), ap("Home", Z.description, rssi: -40)],
                     siblingFindings: [], now: t4)
        let out = m.update(connection: conn("Home", Z, rssi: -40), scan: nil, siblingFindings: [], now: t4 + 10)
        #expect(Set(out.map(\.signal)) == [.louderNewcomer, .movedToFlagged])
    }

    @Test func findingsPersistWithinSession() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(gw: "00:11:22:33:44:01"), scan: nil, siblingFindings: [], now: t0)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 30)
        _ = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 31)
        let out = m.update(connection: conn(gw: "00:11:22:33:44:02"), scan: nil, siblingFindings: [], now: t0 + 32)
        #expect(out.filter { $0.signal == .gatewayChanged }.count == 1)
    }

    private static let tampered = DNSAnswersState.tampered(name: "dns.google", address: "172.19.0.1",
                                                           expected: ["8.8.8.8", "8.8.4.4"])

    @Test func tamperedAnswerRaisesOneConnectionFinding() {
        var m = ConnectionMonitor()
        let out = m.update(connection: conn(answers: Self.tampered), scan: nil, siblingFindings: [], now: t0)
        #expect(out.map(\.signal) == [.dnsTampered])
        #expect(out[0].bssid == nil)
        #expect(out[0].ssid == "Home")
        #expect(out[0].reason == "dns.google resolved to 172.19.0.1 (expected 8.8.8.8 or 8.8.4.4).")
        _ = m.update(connection: conn(answers: Self.tampered), scan: nil, siblingFindings: [], now: t0 + 60)
        let again = m.update(connection: conn(answers: Self.tampered), scan: nil, siblingFindings: [], now: t0 + 120)
        #expect(again.count == 1)
    }

    @Test func tamperedFindingSurvivesLaterAsExpected() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(answers: Self.tampered), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn(answers: .asExpected), scan: nil, siblingFindings: [], now: t0 + 60)
        #expect(out.map(\.signal) == [.dnsTampered])
    }

    @Test func newNetworkClearsTamperedFinding() {
        var m = ConnectionMonitor()
        _ = m.update(connection: conn(answers: Self.tampered), scan: nil, siblingFindings: [], now: t0)
        let out = m.update(connection: conn("Other"), scan: nil, siblingFindings: [], now: t0 + 60)
        #expect(out.isEmpty)
    }

    @Test func otherAnswerStatesRaiseNothing() {
        let states: [DNSAnswersState] = [.notChecked, .off, .noAnswer, .asExpected, .filtered,
                                         .filteredByYourServer(name: "x.test", address: "0.0.0.0"),
                                         .rewritten(address: "10.0.0.1")]
        for state in states {
            var m = ConnectionMonitor()
            let out = m.update(connection: conn(answers: state), scan: nil, siblingFindings: [], now: t0)
            #expect(out.isEmpty)
        }
    }
}
