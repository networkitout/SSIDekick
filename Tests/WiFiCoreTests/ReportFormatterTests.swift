import Testing
import Foundation
@testable import WiFiCore

@Suite struct ReportFormatterTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let vendors = VendorTable(tsv: "A4B1C2\tAcme Networks\n")
    let linkAddress = "a4:b1:c2:00:00:01"
    let otherAddress = "a4:b1:c2:00:00:02"

    func connected(authorized: Bool = true, findings: [Finding] = []) -> Snapshot {
        var snapshot = Snapshot.empty
        snapshot.state = .connected
        snapshot.locationAuthorized = authorized
        snapshot.link = LinkSnapshot(ssid: "Home", bssid: MACAddress(linkAddress), rssi: -58, noise: -92,
                                     txRateMbps: 866, channel: Channel(number: 44, band: .ghz5, widthMHz: 80),
                                     generation: .wifi6, security: .wpa2, countryCode: "US")
        snapshot.scan = [ap("Home", linkAddress, rssi: -58), ap("Home", otherAddress, rssi: -70), ap(nil, "a4:b1:c2:00:00:03")]
        snapshot.findings = findings
        return snapshot
    }

    @Test func connectedReportContainsLinkFacts() {
        let finding = Finding(signal: .vendorMismatch, ssid: "Home", bssid: MACAddress(otherAddress),
                              reason: "Different vendor than its siblings")
        let text = formatReport(connected(findings: [finding]), vendors: vendors, now: now)
        #expect(text.contains("Signal -58 dBm"))
        #expect(text.contains("SNR 34"))
        #expect(text.contains("Ch 44 (5 GHz, 80 MHz)"))
        #expect(text.contains("Different vendor than its siblings"))
        #expect(text.contains("Acme Networks"))
        #expect(text.contains("(hidden)"))
        #expect(text.contains("2027-01-15T08:00:00Z"))
        #expect(!text.contains("No findings."))
    }

    @Test func emptyFindings() {
        let text = formatReport(connected(), vendors: vendors, now: now)
        #expect(text.contains("No findings."))
    }

    @Test func missingValuesPrintNA() {
        let text = formatReport(.empty, vendors: vendors, now: now)
        #expect(text.contains("n/a"))
    }

    @Test func locationDeniedHidesNamesAndAddresses() {
        let finding = Finding(signal: .vendorMismatch, ssid: "Home", bssid: MACAddress(otherAddress), reason: "x")
        let text = formatReport(connected(authorized: false, findings: [finding]), vendors: vendors, now: now)
        #expect(text.contains("hidden (Location Services off)"))
        #expect(!text.contains(linkAddress))
        #expect(!text.contains(otherAddress))
        #expect(!text.contains("Home"))
    }

    @Test func neverClaimsSafety() {
        let text = formatReport(connected(), vendors: vendors, now: now).lowercased()
        #expect(!text.contains("safe") && !text.contains("secure") && !text.contains("verified"))
    }
}
