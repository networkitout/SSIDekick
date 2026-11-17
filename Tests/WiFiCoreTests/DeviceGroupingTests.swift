import Testing
@testable import WiFiCore

@Suite struct DeviceGroupingTests {
    private func radio(_ tail: String, rssi: Int = -60, band: Band = .ghz5, prefix: String = "a4:b1:c2:00") -> AccessPoint {
        ap("Home", "\(prefix):\(tail)", rssi: rssi, band: band)
    }

    @Test func triBandRouterIsOneDevice() {
        let aps = [radio("01:10", band: .ghz2_4), radio("01:14", band: .ghz5), radio("01:18", band: .ghz6)]
        let devices = groupDevices(aps, findings: [])
        #expect(devices.count == 1)
        #expect(devices[0].accessPoints.count == 3)
        #expect(devices[0].addressPattern == "a4:b1:c2:00:01:x")
        #expect(devices[0].bands == [.ghz2_4, .ghz5, .ghz6])
        #expect(devices[0].id == "a4:b1:c2:00:01:10")
        #expect(!devices[0].isSingleRadio)
    }

    @Test func locallyAdministeredSiblingJoinsTheDevice() {
        let aps = [ap("Home", "a6:b1:c2:00:01:11"), ap("Home", "a4:b1:c2:00:01:10")]
        let devices = groupDevices(aps, findings: [])
        #expect(devices.count == 1)
        #expect(devices[0].id == "a4:b1:c2:00:01:10")
        #expect(devices[0].addressPattern == "a4:b1:c2:00:01:x")
    }

    @Test func spanOfSixteenStartsANewDevice() {
        let aps = [radio("01:10", rssi: -50), radio("01:14", rssi: -51), radio("01:20", rssi: -60), radio("01:24", rssi: -61)]
        let devices = groupDevices(aps, findings: [])
        #expect(devices.count == 2)
        #expect(devices.map(\.id) == ["a4:b1:c2:00:01:10", "a4:b1:c2:00:01:20"])
    }

    @Test func spanOfFifteenStaysTogether() {
        let devices = groupDevices([radio("01:10"), radio("01:1f")], findings: [])
        #expect(devices.count == 1)
    }

    @Test func flaggedRadioStaysAloneBesideItsNeighbours() {
        let flagged = radio("01:12", rssi: -40)
        let finding = Finding(signal: .vendorMismatch, ssid: "Home", bssid: flagged.bssid, reason: "different maker")
        let devices = groupDevices([radio("01:10"), radio("01:14"), flagged], findings: [finding])
        #expect(devices.count == 2)
        #expect(devices.reduce(0) { $0 + $1.accessPoints.count } == 3)
        #expect(devices[0].id == "a4:b1:c2:00:01:12")
        #expect(devices[0].isSingleRadio)
        #expect(devices[0].addressPattern == "a4:b1:c2:00:01:12")
        #expect(devices[1].accessPoints.count == 2)
    }

    @Test func missingAddressesStayAlone() {
        let aps = [ap("Home", nil, rssi: -50), ap("Home", nil, rssi: -60)]
        let devices = groupDevices(aps, findings: [])
        #expect(devices.count == 2)
        #expect(devices.allSatisfy { $0.isSingleRadio })
        #expect(devices.allSatisfy { $0.addressPattern == "–" })
        #expect(devices[0].id != devices[1].id)
    }

    @Test func differentByteFourIsSeparate() {
        let devices = groupDevices([radio("01:10"), radio("02:10")], findings: [])
        #expect(devices.count == 2)
    }

    @Test func devicesOrderByStrongestRadio() {
        let aps = [radio("01:10", rssi: -70), radio("01:14", rssi: -65), radio("02:10", rssi: -50)]
        let devices = groupDevices(aps, findings: [])
        #expect(devices[0].id == "a4:b1:c2:00:02:10")
        #expect(devices[1].strongestRSSI == -65)
        #expect(devices[1].accessPoints.map(\.rssi) == [-65, -70])
    }

    @Test func summaryText() {
        func device(_ count: Int, _ n: Int) -> DeviceGroup {
            let aps = (0..<count).map { radio(String(format: "%02x:10", n), rssi: -60 - $0) }
            return DeviceGroup(id: "d\(n)", accessPoints: aps, addressPattern: "", bands: [], strongestRSSI: -60)
        }
        #expect(devicesSummary([device(4, 1), device(2, 2)]) == "6 radios on 2 devices")
        #expect(devicesSummary([device(1, 1)]) == "1 radio on 1 device")
        #expect(devicesSummary([device(1, 1), device(1, 2)]) == "2 radios on 2 devices")
        #expect(devicesSummary([]) == "0 radios on 0 devices")
        #expect(groupDevices([], findings: []).isEmpty)
    }

    private func ids(_ aps: [AccessPoint], findings: [Finding] = []) -> [String] {
        groupDevices(aps, findings: findings).map(\.id)
    }

    @Test func clonedAddressOnTwoChannelsGivesDistinctIds() {
        let a = ap("Home", "a4:b1:c2:00:01:10", rssi: -50, ch: 36)
        let b = ap("Home", "a4:b1:c2:00:01:10", rssi: -60, ch: 149)
        let finding = Finding(signal: .clonedAddress, ssid: "Home", bssid: a.bssid, reason: "seen on two channels")
        let devices = groupDevices([a, b], findings: [finding])
        #expect(devices.count == 2)
        #expect(Set(devices.map(\.id)).count == 2)
        #expect(ids([a, b], findings: [finding]) == ids([a, b], findings: [finding]))
    }

    @Test func sameAddressSameChannelStillGivesDistinctIds() {
        let a = ap("Home", "a4:b1:c2:00:01:10", rssi: -50, ch: 36)
        let b = ap("Home", "a4:b1:c2:00:01:10", rssi: -60, ch: 36)
        let c = ap("Home", "a4:b1:c2:00:01:10", rssi: -70, ch: 36)
        let finding = Finding(signal: .clonedAddress, ssid: "Home", bssid: a.bssid, reason: "dup")
        let flagged = ids([a, b, c], findings: [finding])
        #expect(flagged.count == 3 && Set(flagged).count == 3)
        let plain = ids([a, b, c])
        #expect(Set(plain).count == plain.count)
    }
}
