import Foundation
import Testing
import WiFiCore
@testable import WiFiSystem

// MARK: - Fakes

private func mac(_ s: String) -> MACAddress { MACAddress(s)! }

private func ap(_ ssid: String, _ bssid: String, rssi: Int = -60) -> AccessPoint {
    AccessPoint(ssid: ssid, bssid: mac(bssid), rssi: rssi, noise: -90,
                channel: Channel(number: 44, band: .ghz5, widthMHz: 80),
                security: [.wpa2], generation: .wifi6, countryCode: "US", beaconInterval: 100)
}

private func makeLink(_ ssid: String?, _ bssid: String?) -> LinkSnapshot {
    LinkSnapshot(ssid: ssid, bssid: bssid.map(mac), rssi: -60, noise: -90, txRateMbps: 433,
                 channel: Channel(number: 44, band: .ghz5, widthMHz: 80), generation: .wifi6,
                 security: .wpa2, countryCode: "US")
}

private struct FakeScanError: Error {}

private final class FakeWiFi: WiFiSource {
    var wifiState: WiFiState = .connected
    var link: LinkSnapshot? = makeLink("Corp", "00:0b:86:00:00:01")
    var scans: [Result<[AccessPoint], Error>] = []

    func state() -> WiFiState { wifiState }
    func currentLink() -> LinkSnapshot? { link }
    func cachedScan() -> [AccessPoint] { [] }
    func scan() async throws -> [AccessPoint] { try scans.removeFirst().get() }
    var events: AsyncStream<WiFiEvent> { AsyncStream { $0.finish() } }
}

private final class FakeConfig: NetworkConfigSource {
    var config = NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["192.168.1.1"], ipv4: ["192.168.1.20"], ipv6: [])
    func current() -> NetworkConfig { config }
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class FakeNeighbors: NeighborSource {
    var answers: [MACAddress?] = []
    func hardwareAddress(forIPv4 ip: String) async -> MACAddress? {
        answers.isEmpty ? nil : answers.removeFirst()
    }
}

private final class FakeProber: Prober {
    var pingCount = 0
    var publicIPCount = 0
    func ping(_ ip: String) async -> Double? { pingCount += 1; return 2 }
    func dnsLatency(server: String) async -> Double? { 10 }
    func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) { (.online, 30) }
    func publicIP() async -> String? { publicIPCount += 1; return "203.0.113.5" }
}

private final class FakeLocation: LocationAuthorizing {
    var isAuthorized = true
    var isDetermined = true
    func request() {}
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

@MainActor
private final class Recorder {
    var calls: [[Finding]] = []
}

@MainActor
private func makeEngine(wifi: FakeWiFi = FakeWiFi(), config: FakeConfig = FakeConfig(),
                        neighbors: FakeNeighbors = FakeNeighbors(), prober: FakeProber = FakeProber(),
                        location: FakeLocation = FakeLocation(),
                        settings: EngineSettings = EngineSettings()) -> Engine {
    Engine(wifi: wifi, config: config, neighbors: neighbors, prober: prober, location: location,
           vendors: VendorTable.empty, settings: settings, now: { t0 })
}

@MainActor
private func makeDemoEngine(_ scenario: DemoScenario, recorder: Recorder) -> Engine {
    let s = demoSources(scenario)
    let engine = Engine(wifi: s.wifi, config: s.config, neighbors: s.neighbors, prober: s.prober,
                        location: s.location, vendors: s.vendors, settings: EngineSettings(), now: { t0 })
    engine.onNewFindings = { recorder.calls.append($0) }
    return engine
}

// MARK: - Tests

@MainActor
struct EngineTests {
    @Test func planeTwinTurnsAmber() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.planeTwin, recorder: recorder)
        engine.refreshLink()
        await engine.scanNow()
        #expect(engine.snapshot.connectedVerdict == .worthALook)
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.contains { $0.signal == .vendorMismatch } == true)
    }

    @Test func officeStaysClear() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.office, recorder: recorder)
        engine.refreshLink()
        await engine.refreshProbes()
        await engine.scanNow()
        #expect(engine.snapshot.link != nil)
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(recorder.calls.isEmpty)
    }

    @Test func scanFailureKeepsLastResults() async {
        let wifi = FakeWiFi()
        wifi.scans = [
            .success([ap("Corp", "00:0b:86:00:00:01"), ap("Corp", "00:0b:86:00:00:02"), ap("Home", "00:14:6c:00:00:01")]),
            .failure(FakeScanError()),
        ]
        var clock = t0
        let engine = Engine(wifi: wifi, config: FakeConfig(), neighbors: FakeNeighbors(), prober: FakeProber(),
                            location: FakeLocation(), vendors: VendorTable.empty, settings: EngineSettings(),
                            now: { clock })
        await engine.scanNow()
        #expect(engine.snapshot.scanError == nil)
        clock = t0 + 60
        await engine.scanNow()
        #expect(engine.snapshot.scan.count == 3)
        #expect(engine.snapshot.scanTime == t0)
        #expect(engine.snapshot.scanError != nil)
    }

    @Test func locationDeniedHidesFindings() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.locationDenied, recorder: recorder)
        engine.refreshLink()
        await engine.refreshProbes()
        await engine.scanNow()
        #expect(engine.snapshot.locationAuthorized == false)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(recorder.calls.isEmpty)
    }

    @Test func noGatewayNoPing() async {
        let config = FakeConfig()
        config.config.gatewayIP = nil
        let prober = FakeProber()
        let engine = makeEngine(config: config, prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        await engine.refreshProbes()
        #expect(prober.pingCount == 0)
        #expect(engine.snapshot.connectivity.gatewayMAC == nil)
        #expect(engine.snapshot.connectivity.gatewayLatencyMs == nil)
        #expect(engine.snapshot.connectivity.gatewayLossPercent == nil)
    }

    @Test func gatewayChangeTurnsRed() async {
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:14:6c:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let recorder = Recorder()
        let engine = makeEngine(neighbors: neighbors)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .suspect)
        #expect(engine.snapshot.findings.map(\.signal) == [.gatewayChanged])
        #expect(recorder.calls.count == 1)
    }

    @Test func probesFillConnectivity() async {
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:14:6c:aa:00:01")]
        let engine = makeEngine(neighbors: neighbors)
        engine.refreshLink()
        await engine.refreshProbes()
        let c = engine.snapshot.connectivity
        #expect(c.gatewayIP == "192.168.1.1")
        #expect(c.gatewayMAC == mac("00:14:6c:aa:00:01"))
        #expect(c.gatewayLatencyMs == 2)
        #expect(c.gatewayLossPercent == 0)
        #expect(c.dnsLatencyMs == 10)
        #expect(c.internet == .online)
        #expect(c.ipv4 == ["192.168.1.20"])
    }

    @Test func publicIPRespectsSetting() async {
        let prober = FakeProber()
        let engine = makeEngine(prober: prober, settings: EngineSettings(scanInterval: 60, publicIPEnabled: false))
        engine.refreshLink()
        await engine.refreshPublicIP()
        #expect(prober.publicIPCount == 0)
        #expect(engine.snapshot.connectivity.publicIP == nil)
    }

    @Test func publicIPCachedForSessionAndClearedOnNewSession() async {
        let wifi = FakeWiFi()
        let prober = FakeProber()
        let engine = makeEngine(wifi: wifi, prober: prober)
        engine.refreshLink()
        await engine.refreshPublicIP()
        await engine.refreshPublicIP()
        #expect(prober.publicIPCount == 1)
        #expect(engine.snapshot.connectivity.publicIP == "203.0.113.5")
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        engine.refreshLink()
        #expect(engine.snapshot.connectivity.publicIP == nil)
    }

    @Test func notificationNotRepeated() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.planeTwin, recorder: recorder)
        engine.refreshLink()
        await engine.scanNow()
        await engine.scanNow()
        #expect(recorder.calls.count == 1)
    }

    @Test func wifiOff() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.wifiOff, recorder: recorder)
        engine.refreshLink()
        await engine.refreshProbes()
        await engine.scanNow()
        #expect(engine.snapshot.state == .off)
        #expect(engine.snapshot.link == nil)
        #expect(engine.snapshot.connectedVerdict == .clear)
    }

    @Test func clonedAddressTurnsRed() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.clonedAddress, recorder: recorder)
        engine.refreshLink()
        await engine.scanNow()
        #expect(engine.snapshot.connectedVerdict == .suspect)
        #expect(engine.snapshot.findings.contains { $0.signal == .clonedAddress })
    }

    @Test func louderNewcomerNeedsTwoCompletedScans() async {
        let wifi = FakeWiFi()
        let base = [ap("Corp", "00:0b:86:00:00:01"), ap("Corp", "00:0b:86:00:00:02")]
        wifi.scans = [.success(base), .success(base + [ap("Corp", "00:0b:86:00:00:09", rssi: -40)])]
        let engine = makeEngine(wifi: wifi)
        engine.refreshLink()
        await engine.scanNow()
        engine.refreshLink()   // must not hand the same scan to the monitor again
        #expect(engine.snapshot.connectedVerdict == .clear)
        await engine.scanNow()
        #expect(engine.snapshot.findings.map(\.signal) == [.louderNewcomer])
        #expect(engine.snapshot.connectedVerdict == .worthALook)
    }

    @Test func everyDemoScenarioBuilds() {
        for scenario in DemoScenario.allCases {
            let s = demoSources(scenario)
            #expect(s.wifi.cachedScan().allSatisfy { $0.bssid.map { !$0.isLocallyAdministered } ?? true })
        }
    }
}
