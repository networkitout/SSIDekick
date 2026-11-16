import Testing
@testable import WiFiCore

private func finding(_ signal: Signal, ssid: String = "Net", bssid: String? = "a4:b1:c2:00:00:01") -> Finding {
    Finding(signal: signal, ssid: ssid, bssid: bssid.flatMap { MACAddress($0) }, reason: "r")
}

@Suite struct VerdictTests {
    @Test func strengthsMatchTheTiers() {
        for signal in [Signal.securityMismatch, .clonedAddress, .gatewayChanged, .dnsChanged] { #expect(signal.strength == .strong) }
        for signal in [Signal.vendorMismatch, .louderNewcomer, .movedToFlagged] { #expect(signal.strength == .medium) }
        for signal in [Signal.locallyAdministered, .countryMismatch, .beaconMismatch, .generationMismatch] { #expect(signal.strength == .weak) }
    }
    @Test func noFindingsIsClear() { #expect(verdict(for: []) == .clear) }
    @Test func oneWeakIsNote() { #expect(verdict(for: [finding(.countryMismatch)]) == .note) }
    @Test func twoWeakIsWorthALook() {
        #expect(verdict(for: [finding(.countryMismatch), finding(.beaconMismatch)]) == .worthALook)
    }
    @Test func oneMediumIsWorthALook() { #expect(verdict(for: [finding(.vendorMismatch)]) == .worthALook) }
    @Test func anyStrongIsSuspect() {
        #expect(verdict(for: [finding(.securityMismatch)]) == .suspect)
        #expect(verdict(for: [finding(.countryMismatch), finding(.clonedAddress)]) == .suspect)
    }
    @Test func networkVerdictTakesWorstAddress() {
        let findings = [
            finding(.countryMismatch, bssid: "a4:b1:c2:00:00:01"),
            finding(.securityMismatch, bssid: "a4:b1:c2:00:00:02"),
            finding(.securityMismatch, ssid: "Other", bssid: "a4:b1:c2:00:00:03"),
        ]
        #expect(networkVerdict(ssid: "Net", findings: findings) == .suspect)
        #expect(networkVerdict(ssid: "Quiet", findings: findings) == .clear)
    }
    @Test func networkVerdictCountsConnectionWideFindings() {
        #expect(networkVerdict(ssid: "Net", findings: [finding(.gatewayChanged, bssid: nil)]) == .suspect)
    }
    @Test func weakSignalsOnDifferentAddressesDoNotAddUp() {
        let findings = [finding(.countryMismatch, bssid: "a4:b1:c2:00:00:01"), finding(.beaconMismatch, bssid: "a4:b1:c2:00:00:02")]
        #expect(networkVerdict(ssid: "Net", findings: findings) == .note)
    }
}
