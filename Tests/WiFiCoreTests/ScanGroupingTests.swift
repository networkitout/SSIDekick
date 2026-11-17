import Foundation
import Testing
import WiFiCore

private func finding(_ signal: Signal, ssid: String, bssid: String?) -> Finding {
    Finding(signal: signal, ssid: ssid, bssid: bssid.flatMap { MACAddress($0) }, reason: "r")
}

@Suite struct ScanGroupingTests {
    @Test func connectedGroupComesFirstEvenWhenWeaker() {
        let scan = [ap("Loud", "00:00:00:00:00:01", rssi: -40), ap("Mine", "00:00:00:00:00:02", rssi: -80)]
        let groups = groupScan(scan, findings: [], connectedSSID: "Mine")
        #expect(groups.map(\.ssid) == ["Mine", "Loud"])
        #expect(groups[0].isConnected)
        #expect(!groups[1].isConnected)
    }

    @Test func suspectGroupSortsAboveStrongerClearGroup() {
        let scan = [ap("Clear", "00:00:00:00:00:01", rssi: -30), ap("Bad", "00:00:00:00:00:02", rssi: -80)]
        let findings = [finding(.securityMismatch, ssid: "Bad", bssid: "00:00:00:00:00:02")]
        let groups = groupScan(scan, findings: findings, connectedSSID: nil)
        #expect(groups.map(\.ssid) == ["Bad", "Clear"])
        #expect(groups[0].verdict == .suspect)
        #expect(groups[1].verdict == .clear)
    }

    @Test func verdictOrderThenStrongestSignal() {
        let scan = [
            ap("Weak", "00:00:00:00:00:01", rssi: -85),
            ap("Strong", "00:00:00:00:00:02", rssi: -45),
            ap("Look", "00:00:00:00:00:03", rssi: -90),
        ]
        let findings = [finding(.vendorMismatch, ssid: "Look", bssid: "00:00:00:00:00:03")]
        #expect(groupScan(scan, findings: findings, connectedSSID: nil).map(\.ssid) == ["Look", "Strong", "Weak"])
    }

    @Test func namelessEntriesAreSeparateGroupsAtTheEnd() {
        let scan = [
            ap(nil, "00:00:00:00:00:01", rssi: -30),
            ap("Named", "00:00:00:00:00:02", rssi: -80),
            ap(nil, "00:00:00:00:00:03", rssi: -50),
        ]
        let groups = groupScan(scan, findings: [], connectedSSID: nil)
        #expect(groups.count == 3)
        #expect(groups[0].ssid == "Named")
        #expect(groups[1].ssid == nil && groups[2].ssid == nil)
        #expect(groups[1].id != groups[2].id)
        #expect(Set(groups.map(\.id)).count == 3)
        #expect(groups[1].verdict == .clear)
    }

    @Test func accessPointsWithinGroupAreStrongestFirst() {
        let scan = [
            ap("Net", "00:00:00:00:00:01", rssi: -70),
            ap("Net", "00:00:00:00:00:02", rssi: -50),
            ap("Net", "00:00:00:00:00:03", rssi: -60),
        ]
        let groups = groupScan(scan, findings: [], connectedSSID: nil)
        #expect(groups.count == 1)
        #expect(groups[0].accessPoints.map(\.rssi) == [-50, -60, -70])
    }

    @Test func groupVerdictIsWorstAddress() {
        let scan = [ap("Net", "00:00:00:00:00:01"), ap("Net", "00:00:00:00:00:02")]
        let findings = [
            finding(.countryMismatch, ssid: "Net", bssid: "00:00:00:00:00:01"),
            finding(.clonedAddress, ssid: "Net", bssid: "00:00:00:00:00:02"),
        ]
        #expect(groupScan(scan, findings: findings, connectedSSID: nil)[0].verdict == .suspect)
    }

    @Test func weakFindingsOnDifferentAddressesDoNotAddUp() {
        let scan = [ap("Net", "00:00:00:00:00:01"), ap("Net", "00:00:00:00:00:02")]
        let findings = [
            finding(.countryMismatch, ssid: "Net", bssid: "00:00:00:00:00:01"),
            finding(.beaconMismatch, ssid: "Net", bssid: "00:00:00:00:00:02"),
        ]
        #expect(groupScan(scan, findings: findings, connectedSSID: nil)[0].verdict == .note)
    }

    @Test func connectionLevelFindingCountsForConnectedGroupOnly() {
        let scan = [ap("Mine", "00:00:00:00:00:01"), ap("Other", "00:00:00:00:00:02")]
        let findings = [finding(.gatewayChanged, ssid: "Mine", bssid: nil),
                        finding(.dnsChanged, ssid: "Other", bssid: nil)]
        let groups = groupScan(scan, findings: findings, connectedSSID: "Mine")
        #expect(groups[0].ssid == "Mine" && groups[0].verdict == .suspect)
        #expect(groups[1].ssid == "Other" && groups[1].verdict == .clear)
    }

    @Test func rowFindingsMatchSSIDAndAddress() {
        let a = ap("Net", "00:00:00:00:00:01")
        let all = [
            finding(.vendorMismatch, ssid: "Net", bssid: "00:00:00:00:00:01"),
            finding(.vendorMismatch, ssid: "Net", bssid: "00:00:00:00:00:02"),
            finding(.vendorMismatch, ssid: "Other", bssid: "00:00:00:00:00:01"),
            finding(.gatewayChanged, ssid: "Net", bssid: nil),
        ]
        #expect(findings(for: a, in: all).count == 1)
        #expect(findings(for: ap(nil, "00:00:00:00:00:01"), in: all).isEmpty)
    }
}

@Suite struct ScanDisplayTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    @Test func ageText() {
        #expect(scanAgeText(scanTime: nil, now: now) == "Not scanned yet")
        #expect(scanAgeText(scanTime: now, now: now) == "Scanned just now")
        #expect(scanAgeText(scanTime: now.addingTimeInterval(-12), now: now) == "Scanned 12 s ago")
        #expect(scanAgeText(scanTime: now.addingTimeInterval(-59), now: now) == "Scanned 59 s ago")
        #expect(scanAgeText(scanTime: now.addingTimeInterval(-150), now: now) == "Scanned 2 min ago")
        #expect(scanAgeText(scanTime: now.addingTimeInterval(5), now: now) == "Scanned just now")
    }

    @Test func opacityScalesAndClamps() {
        #expect(signalOpacity(rssi: -90) == 0.25)
        #expect(signalOpacity(rssi: -120) == 0.25)
        #expect(signalOpacity(rssi: -40) == 1.0)
        #expect(signalOpacity(rssi: -10) == 1.0)
        #expect(abs(signalOpacity(rssi: -65) - 0.625) < 1e-9)
    }
}
