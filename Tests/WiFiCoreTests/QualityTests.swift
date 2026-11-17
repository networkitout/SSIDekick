import Testing
import WiFiCore

@Suite struct QualityTests {
    @Test func signalLevels() {
        #expect(signalLevel(rssi: -60) == .good)
        #expect(signalLevel(rssi: -61) == .fair)
        #expect(signalLevel(rssi: -70) == .fair)
        #expect(signalLevel(rssi: -71) == .poor)
        #expect(signalLevel(rssi: 0) == .unknown)
    }

    @Test func bars() {
        #expect(signalBars(rssi: -55) == 4)
        #expect(signalBars(rssi: -56) == 3)
        #expect(signalBars(rssi: -65) == 3)
        #expect(signalBars(rssi: -66) == 2)
        #expect(signalBars(rssi: -75) == 2)
        #expect(signalBars(rssi: -76) == 1)
        #expect(signalBars(rssi: 0) == 0)
    }

    @Test func snr() {
        #expect(snrLevel(25) == .good)
        #expect(snrLevel(24) == .fair)
        #expect(snrLevel(15) == .fair)
        #expect(snrLevel(14) == .poor)
    }

    @Test func snrFromReadings() {
        #expect(snrLevel(rssi: -58, noise: -92) == .good)
        #expect(snrLevel(rssi: -60, noise: 0) == .unknown)
        #expect(snrLevel(rssi: 0, noise: -90) == .unknown)
    }

    @Test func gatewayLatency() {
        #expect(gatewayLatencyLevel(19.4) == .good)
        #expect(gatewayLatencyLevel(19.6) == .fair)
        #expect(gatewayLatencyLevel(20) == .fair)
        #expect(gatewayLatencyLevel(100) == .fair)
        #expect(gatewayLatencyLevel(100.4) == .fair)
        #expect(gatewayLatencyLevel(100.6) == .poor)
        #expect(gatewayLatencyLevel(nil) == .unknown)
    }

    @Test func loss() {
        #expect(lossLevel(0) == .good)
        #expect(lossLevel(1) == .fair)
        #expect(lossLevel(5) == .fair)
        #expect(lossLevel(6) == .poor)
        #expect(lossLevel(nil) == .unknown)
    }

    @Test func dnsLatency() {
        #expect(dnsLatencyLevel(49.4) == .good)
        #expect(dnsLatencyLevel(49.6) == .fair)
        #expect(dnsLatencyLevel(50) == .fair)
        #expect(dnsLatencyLevel(200) == .fair)
        #expect(dnsLatencyLevel(200.4) == .fair)
        #expect(dnsLatencyLevel(200.6) == .poor)
        #expect(dnsLatencyLevel(nil) == .unknown)
    }

    @Test func internet() {
        #expect(internetLevel(.online) == .good)
        #expect(internetLevel(.captivePortal) == .fair)
        #expect(internetLevel(.offline) == .poor)
        #expect(internetLevel(.unknown) == .unknown)
    }

    @Test func gatewayLevelIsWorseOfLatencyAndLoss() {
        var net = ConnectivitySnapshot()
        net.gatewayLatencyMs = 5
        net.gatewayLossPercent = 10
        #expect(gatewayLevel(net) == .poor)
        net.gatewayLossPercent = nil
        #expect(gatewayLevel(net) == .good)
        net.gatewayLatencyMs = nil
        net.gatewayLossPercent = 3
        #expect(gatewayLevel(net) == .fair)
        net.gatewayLossPercent = nil
        #expect(gatewayLevel(net) == .unknown)
        net.gatewayLatencyMs = 5
        net.gatewayLossPercent = 10
        net.gatewayBlocked = true
        #expect(gatewayLevel(net) == .unknown)
    }

    @Test func dnsLevelFollowsLatencyUnlessBlocked() {
        var net = ConnectivitySnapshot()
        net.dnsLatencyMs = 300
        #expect(dnsLevel(net) == .poor)
        net.dnsBlocked = true
        #expect(dnsLevel(net) == .unknown)
    }

    @Test func comparableFollowsRawValues() {
        #expect(QualityLevel.good < .fair)
        #expect(QualityLevel.fair < .poor)
        #expect(QualityLevel.unknown < .good)
    }
}
