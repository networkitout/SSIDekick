import Testing
@testable import WiFiCore

private struct StubVendors: VendorLookup {
    func vendor(for address: MACAddress) -> String? {
        guard !address.isLocallyAdministered else { return nil }
        switch address.oui {
        case 0xa4b1c2: return "Acme"
        case 0x001122: return "Other"
        default: return nil
        }
    }
}

private let detector = TwinDetector(vendors: StubVendors())

private func acme(_ n: Int) -> String { "a4:b1:c2:00:00:" + String(n, radix: 16).leftPad() }
private extension String { func leftPad() -> String { count < 2 ? "0" + self : self } }

@Suite struct TwinDetectorTests {
    @Test func officeIsSilent() {
        let scan = [
            ap("Corp", acme(1), ch: 1, band: .ghz2_4), ap("Corp", acme(2), ch: 6, band: .ghz2_4),
            ap("Corp", acme(3), ch: 11, band: .ghz2_4), ap("Corp", acme(4), ch: 36),
            ap("Corp", acme(5), ch: 44), ap("Corp", acme(6), ch: 149),
        ]
        #expect(detector.findings(in: scan).isEmpty)
    }
    @Test func multiRadioDeviceIsSilent() {
        let scan = [ap("Home", "a4:b1:c2:00:01:00", ch: 6, band: .ghz2_4), ap("Home", "a4:b1:c2:00:01:04", ch: 44)]
        #expect(detector.findings(in: scan).isEmpty)
    }
    @Test func singleAccessPointIsSilent() { #expect(detector.findings(in: [ap("Cafe", acme(1))]).isEmpty) }

    @Test func openTwinAmongEncrypted() throws {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", acme(3)), ap("Corp", acme(4), sec: [.open])]
        let found = detector.findings(in: scan)
        #expect(found.count == 1)
        let f = try #require(found.first)
        #expect(f.signal == .securityMismatch)
        #expect(f.bssid == MACAddress(acme(4)))
        #expect(f.reason == "Open, while 3 others named Corp use WPA2")
        #expect(verdict(for: found) == .suspect)
    }
    @Test func differentVendorTwin() {
        let scan = [ap("Inflight", acme(1)), ap("Inflight", acme(2)), ap("Inflight", acme(3)), ap("Inflight", "00:11:22:00:00:01")]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.vendorMismatch])
        #expect(found.first?.bssid == MACAddress("00:11:22:00:00:01"))
    }
    @Test func twoVendorsOneEachIsSilent() {
        #expect(detector.findings(in: [ap("Inflight", acme(1)), ap("Inflight", "00:11:22:00:00:01")]).isEmpty)
    }
    @Test func clonedAddressTwoChannels() {
        let scan = [ap("Corp", acme(1), ch: 36), ap("Corp", acme(1), ch: 149)]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.clonedAddress])
        #expect(found.first?.bssid == MACAddress(acme(1)))
    }
    @Test func softwareAddressAmongRealOnes() {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", "02:11:22:33:44:55")]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.locallyAdministered])
        #expect(verdict(for: found) == .note)
    }
    @Test func weakSignalsAddUp() {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", acme(3), cc: "DE", beacon: 102)]
        let found = detector.findings(in: scan)
        #expect(Set(found.map(\.signal)) == [.countryMismatch, .beaconMismatch])
        #expect(found.count == 2)
        #expect(verdict(for: found) == .worthALook)
    }
    @Test func generationMismatchNeedsUnanimousSiblings() {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", acme(3), gen: .wifi4)]
        #expect(detector.findings(in: scan).map(\.signal) == [.generationMismatch])
        let split = [ap("Corp", acme(1)), ap("Corp", acme(2), gen: .wifi5), ap("Corp", acme(3), gen: .wifi4)]
        #expect(detector.findings(in: split).isEmpty)
    }
    @Test func nilCountryTwinAmongUnanimousSiblings() {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", acme(3), cc: nil)]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.countryMismatch])
        #expect(found.first?.reason == "No country set, while 2 others named Corp use US")
    }
    @Test func nilGenerationTwinAmongUnanimousSiblings() {
        let scan = [ap("Corp", acme(1)), ap("Corp", acme(2)), ap("Corp", acme(3), gen: nil)]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.generationMismatch])
        #expect(found.first?.reason == "No Wi-Fi generation reported, while 2 others named Corp use Wi-Fi 6")
    }
    @Test func hiddenAndNamelessSkipped() {
        let scan = [
            ap(nil, acme(1)), ap(nil, acme(2), sec: [.open]),
            ap("Ghost", nil), ap("Ghost", nil, sec: [.open]),
        ]
        #expect(detector.findings(in: scan).isEmpty)
    }
    @Test func differentNamesNeverCompared() {
        #expect(detector.findings(in: [ap("A", acme(1), sec: [.open]), ap("B", acme(2))]).isEmpty)
    }
}
