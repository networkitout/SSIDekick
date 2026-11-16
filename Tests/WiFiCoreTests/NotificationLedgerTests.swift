import Testing
@testable import WiFiCore

@Suite struct NotificationLedgerTests {
    let address = MACAddress("a4:b1:c2:00:00:01")
    func medium(_ ssid: String = "Home") -> Finding {
        Finding(signal: .vendorMismatch, ssid: ssid, bssid: address, reason: "vendor differs")
    }

    @Test func worthALookReturnedOnce() {
        var ledger = NotificationLedger()
        #expect(ledger.pending(findings: [medium()], connectedSSID: "Home", sessionID: 1) == [medium()])
        #expect(ledger.pending(findings: [medium()], connectedSSID: "Home", sessionID: 1).isEmpty)
    }

    @Test func loneWeakFindingNeverReturned() {
        var ledger = NotificationLedger()
        let weak = Finding(signal: .countryMismatch, ssid: "Home", bssid: address, reason: "country")
        #expect(ledger.pending(findings: [weak], connectedSSID: "Home", sessionID: 1).isEmpty)
    }

    @Test func otherNetworkNeverReturned() {
        var ledger = NotificationLedger()
        #expect(ledger.pending(findings: [medium("Cafe")], connectedSSID: "Home", sessionID: 1).isEmpty)
        #expect(ledger.pending(findings: [medium()], connectedSSID: nil, sessionID: 1).isEmpty)
    }

    @Test func returnsAgainAfterSessionChange() {
        var ledger = NotificationLedger()
        _ = ledger.pending(findings: [medium()], connectedSSID: "Home", sessionID: 1)
        #expect(ledger.pending(findings: [medium()], connectedSSID: "Home", sessionID: 2) == [medium()])
    }

    @Test func nilAddressBucketCounts() {
        var ledger = NotificationLedger()
        let gateway = Finding(signal: .gatewayChanged, ssid: "Home", bssid: nil, reason: "gateway moved")
        #expect(ledger.pending(findings: [gateway], connectedSSID: "Home", sessionID: 1) == [gateway])
    }

    @Test func twoWeakFindingsOnOneAccessPointQualify() {
        var ledger = NotificationLedger()
        let a = Finding(signal: .countryMismatch, ssid: "Home", bssid: address, reason: "country")
        let b = Finding(signal: .beaconMismatch, ssid: "Home", bssid: address, reason: "beacon")
        #expect(Set(ledger.pending(findings: [a, b], connectedSSID: "Home", sessionID: 1)) == [a, b])
    }
}
