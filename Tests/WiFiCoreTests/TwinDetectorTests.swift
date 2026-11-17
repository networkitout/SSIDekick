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

    // MARK: Security across mixed-WPA routers (C1)

    @Test func triBandRouterIsSilent() {
        let scan = [
            ap("Home", "a4:b1:c2:00:01:00", ch: 6, band: .ghz2_4, width: 20, sec: [.wpa2, .wpa3]),
            ap("Home", "a4:b1:c2:00:01:01", ch: 44, sec: [.wpa2, .wpa3]),
            ap("Home", "a4:b1:c2:00:01:02", ch: 37, band: .ghz6, width: 160, sec: [.wpa3]),
        ]
        #expect(detector.findings(in: scan).isEmpty)
    }
    @Test func twoRadioSplitSecurityIsSilent() {
        let scan = [
            ap("Home", "a4:b1:c2:00:01:00", ch: 6, band: .ghz2_4, width: 20, sec: [.wpa2]),
            ap("Home", "a4:b1:c2:00:01:01", ch: 44, sec: [.wpa3]),
        ]
        #expect(detector.findings(in: scan).isEmpty)
    }
    @Test func openTwinBesideOneWPA2() throws {
        let found = detector.findings(in: [ap("Corp", acme(1)), ap("Corp", acme(2), sec: [.open])])
        #expect(found.map(\.signal) == [.securityMismatch])
        let f = try #require(found.first)
        #expect(f.bssid == MACAddress(acme(2)))
        #expect(f.reason == "Open, while 1 other named Corp uses WPA2")
        #expect(verdict(for: found) == .suspect)
    }
    @Test func wepTwinBesideOneWPA3() {
        let found = detector.findings(in: [ap("Corp", acme(1), sec: [.wpa3]), ap("Corp", acme(2), sec: [.wep])])
        #expect(found.map(\.signal) == [.securityMismatch])
    }
    @Test func weakerGenerationThanMajority() throws {
        let scan = [ap("Corp", acme(1), sec: [.wpa3]), ap("Corp", acme(2), sec: [.wpa3]),
                    ap("Corp", acme(3), sec: [.wpa3]), ap("Corp", acme(4), sec: [.wpa2])]
        let found = detector.findings(in: scan)
        #expect(found.map(\.signal) == [.securityMismatch])
        let f = try #require(found.first)
        #expect(f.bssid == MACAddress(acme(4)))
        #expect(f.reason == "WPA2, while 3 others named Corp use WPA3")
    }
    @Test func evenGenerationSplitIsSilent() {
        let scan = [ap("Corp", acme(1), sec: [.wpa2]), ap("Corp", acme(2), sec: [.wpa2]),
                    ap("Corp", acme(3), sec: [.wpa3]), ap("Corp", acme(4), sec: [.wpa3])]
        #expect(detector.findings(in: scan).isEmpty)
    }

    // MARK: Reason grammar

    @Test func oneSiblingReasonIsSingular() {
        let found = detector.findings(in: [ap("Corp", acme(1)), ap("Corp", "02:11:22:33:44:55")])
        #expect(found.map(\.reason) == ["Software-assigned address, while 1 other named Corp uses hardware addresses"])
    }

    // MARK: Vendor names

    @Test func vendorKeyNormalises() {
        #expect(vendorKey("Ubiquiti Inc") == vendorKey("Ubiquiti Networks Inc."))
        #expect(vendorKey("Cisco Systems, Inc") == vendorKey("Cisco Meraki"))
        #expect(vendorKey("Shenzhen Foo Tech") != vendorKey("Shenzhen Bar Tech"))
        #expect(vendorKey("Acme") != vendorKey("Other"))
        #expect(vendorKey("The Shenzhen") == "the shenzhen")
        #expect(vendorKey("Hon Hai Precision Ind. Co.,Ltd.") == "precision")
    }
    @Test func vendorSpellingVariantsAreOneVendor() {
        let table = VendorTable(tsv: "A4B1C2\tUbiquiti Networks Inc.\nA4B1C3\tUbiquiti Inc\n")
        let scan = [ap("Corp", "a4:b1:c2:00:00:01"), ap("Corp", "a4:b1:c2:00:00:02"), ap("Corp", "a4:b1:c3:00:00:03")]
        #expect(TwinDetector(vendors: table).findings(in: scan).isEmpty)
    }
    @Test func vendorReasonDeterministicOnTie() {
        let table = VendorTable(tsv: "0000A1\tZeta Corp\n0000B1\tBeta Ltd\n0000C1\tAcme\n")
        let scan = [ap("Corp", "00:00:a1:00:00:01"), ap("Corp", "00:00:a1:00:00:02"),
                    ap("Corp", "00:00:b1:00:00:01"), ap("Corp", "00:00:b1:00:00:02"),
                    ap("Corp", "00:00:c1:00:00:01")]
        for _ in 0..<20 {
            let found = TwinDetector(vendors: table).findings(in: scan)
            #expect(found.map(\.reason) == ["Made by Acme, while 2 others named Corp are made by Beta Ltd"])
        }
    }
}
