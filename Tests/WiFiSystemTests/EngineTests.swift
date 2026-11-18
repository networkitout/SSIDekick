import Foundation
import Testing
import WiFiCore
@testable import WiFiSystem

// MARK: - Fakes

private func mac(_ s: String) -> MACAddress { MACAddress(s)! }

private func ap(_ ssid: String?, _ bssid: String?, rssi: Int = -60, ch: Int = 44) -> AccessPoint {
    AccessPoint(ssid: ssid, bssid: bssid.map(mac), rssi: rssi, noise: -90,
                channel: Channel(number: ch, band: .ghz5, widthMHz: 80),
                security: [.wpa2], generation: .wifi6, countryCode: "US", beaconInterval: 100)
}

private func makeLink(_ ssid: String?, _ bssid: String?) -> LinkSnapshot {
    LinkSnapshot(ssid: ssid, bssid: bssid.map(mac), rssi: -60, noise: -90, txRateMbps: 433,
                 channel: Channel(number: 44, band: .ghz5, widthMHz: 80), generation: .wifi6,
                 security: .wpa2, countryCode: "US")
}

private struct FakeScanError: Error {}

/// Shared record of the order in which fakes were called.
private final class CallLog {
    var entries: [String] = []
}

private final class FakeWiFi: WiFiSource {
    var wifiState: WiFiState = .connected
    var link: LinkSnapshot? = makeLink("Corp", "00:0b:86:00:00:01")
    var scans: [Result<[AccessPoint], Error>] = []
    /// Returned once `scans` runs out.
    var defaultScan: [AccessPoint] = []
    var cached: [AccessPoint] = []
    var monitoringError: String?
    var clock: Clock?
    /// Clock time at the start of every scan.
    var scanTimes: [Date] = []
    var scanCount: Int { scanTimes.count }
    /// Runs while a scan is in flight.
    var duringScan: (() async -> Void)?
    let (eventStream, eventContinuation) = AsyncStream<WiFiEvent>.makeStream()

    func state() -> WiFiState { wifiState }
    func currentLink() -> LinkSnapshot? { link }
    func cachedScan() -> [AccessPoint] { cached }
    func scan() async throws -> [AccessPoint] {
        scanTimes.append(clock?.date ?? t0)
        if let duringScan { await duringScan() }
        return try scans.isEmpty ? defaultScan : scans.removeFirst().get()
    }
    var events: AsyncStream<WiFiEvent> { eventStream }
    func emit(_ events: WiFiEvent...) { for event in events { eventContinuation.yield(event) } }
}

private final class FakeConfig: NetworkConfigSource {
    var config = NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["192.168.1.1"], ipv4: ["192.168.1.20"], ipv6: [])
    func current() -> NetworkConfig { config }
    var changes: AsyncStream<Void> { AsyncStream { $0.finish() } }
}

private final class FakeNeighbors: NeighborSource {
    var answers: [MACAddress?] = []
    /// Returned once `answers` runs out.
    var answer: MACAddress?
    var lookups = 0
    var log: CallLog?
    /// Runs while the lookup is suspended, before it answers.
    var duringLookup: (() async -> Void)?
    func hardwareAddress(forIPv4 ip: String) async -> MACAddress? {
        lookups += 1
        log?.entries.append("arp")
        if let duringLookup { await duringLookup() }
        return answers.isEmpty ? answer : answers.removeFirst()
    }
}

private final class FakeProber: Prober {
    var pingCount = 0
    var publicIPCount = 0
    var internetCount = 0
    var log: CallLog?
    /// Answers for successive pings; 2 ms once they run out.
    var pingResults: [PingResult] = []
    var dnsResult: PingResult = .reply(10)
    func ping(_ ip: String) async -> PingResult {
        pingCount += 1
        log?.entries.append("ping")
        return pingResults.isEmpty ? .reply(2) : pingResults.removeFirst()
    }
    func dnsLatency(server: String) async -> PingResult { dnsResult }
    /// The Engine runs the lookups concurrently, so the count is kept under a lock.
    private let lookupLock = NSLock()
    private var lookupCalls = 0
    var lookupCount: Int { lookupLock.withLock { lookupCalls } }
    /// Answers keyed by name; names under example.com use the key "madeUp".
    var lookups: [String: DNSLookup] = [
        "one.one.one.one": .answered(["1.1.1.1", "1.0.0.1"]),
        "dns.google": .answered(["8.8.8.8", "8.8.4.4"]),
        "madeUp": .nameError,
    ]
    /// Runs inside every lookup, before it answers.
    var duringLookup: (() async -> Void)?
    func dnsLookup(name: String, server: String) async -> DNSLookup {
        lookupLock.withLock { lookupCalls += 1 }
        if let duringLookup { await duringLookup() }
        return lookups[name.hasSuffix(".example.com") ? "madeUp" : name] ?? .failed
    }
    var internetStatus: InternetStatus = .online
    func internetCheck() async -> (status: InternetStatus, latencyMs: Double?) {
        internetCount += 1
        return (internetStatus, internetStatus == .online ? 30 : nil)
    }
    func publicIP() async -> String? { publicIPCount += 1; return "203.0.113.5" }
    var httpsResult: HTTPSState = .direct
    var httpsCount = 0
    func httpsCheck() async -> HTTPSState { httpsCount += 1; return httpsResult }
}

private final class FakeLocation: LocationAuthorizing {
    var isAuthorized = true
    var isDetermined = true
    func request() {}
    let (changeStream, changeContinuation) = AsyncStream<Void>.makeStream()
    var changes: AsyncStream<Void> { changeStream }
}

/// Counts vendor lookups, to see when the twin detector runs.
private final class CountingVendors: VendorLookup, @unchecked Sendable {
    var lookups = 0
    func vendor(for address: MACAddress) -> String? { lookups += 1; return nil }
}

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private final class Clock {
    var date = t0
}

/// The Engine's injected sleep. Closed, sleepers wait; open, they return at once. Either way the clock moves on by
/// the time slept, so debounce and spacing are checked without wall-clock waits.
@MainActor
private final class Gate {
    let clock: Clock
    private(set) var isOpen = false
    private var waiters: [(TimeInterval, CheckedContinuation<Void, Never>)] = []
    /// Every sleep asked for, in seconds.
    private(set) var sleeps: [TimeInterval] = []

    init(clock: Clock) { self.clock = clock }

    func sleep(_ seconds: TimeInterval) async -> Bool {
        sleeps.append(seconds)
        if isOpen {
            clock.date += seconds
            return true
        }
        await withCheckedContinuation { waiters.append((seconds, $0)) }
        return true
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for (seconds, continuation) in pending {
            clock.date += seconds
            continuation.resume()
        }
    }
}

/// Opens the gate and waits until no automatic scan is armed or running.
@MainActor
private func settleScans(_ engine: Engine, _ gate: Gate) async {
    gate.open()
    var finished: Task<Void, Never>?
    while let task = engine.armedScanTask, task != finished {
        await task.value
        finished = task
    }
}

/// Finishes the fake's event streams and waits until the Engine has handled every event.
@MainActor
private func drainEvents(_ engine: Engine, wifi: FakeWiFi? = nil, location: FakeLocation? = nil) async {
    if let wifi {
        wifi.eventContinuation.finish()
        await engine.loopTask("wifiEvents")?.value
    }
    if let location {
        location.changeContinuation.finish()
        await engine.loopTask("locationChanges")?.value
    }
}

/// Waits until no probe round is running.
@MainActor
private func settleProbes(_ engine: Engine) async {
    await engine.refreshProbes()
    for _ in 0..<1000 where engine.isProbing { await Task.yield() }
}

@MainActor
private final class Recorder {
    var calls: [[Finding]] = []
}

@MainActor
private func makeEngine(wifi: FakeWiFi = FakeWiFi(), config: FakeConfig = FakeConfig(),
                        neighbors: FakeNeighbors = FakeNeighbors(), prober: FakeProber = FakeProber(),
                        location: FakeLocation = FakeLocation(),
                        settings: EngineSettings = EngineSettings(), clock: Clock = Clock(), gate: Gate? = nil,
                        vendors: VendorLookup = VendorTable.empty) -> Engine {
    wifi.clock = clock
    let gate = gate ?? { let open = Gate(clock: clock); open.open(); return open }()
    return Engine(wifi: wifi, config: config, neighbors: neighbors, prober: prober, location: location,
                  vendors: vendors, settings: settings, now: { clock.date }, sleep: { await gate.sleep($0) })
}

@MainActor
private func makeDemoEngine(_ scenario: DemoScenario, recorder: Recorder, clock: Clock = Clock()) -> Engine {
    let s = demoSources(scenario, now: { clock.date })
    let engine = Engine(wifi: s.wifi, config: s.config, neighbors: s.neighbors, prober: s.prober,
                        location: s.location, vendors: s.vendors, settings: EngineSettings(), now: { clock.date })
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

    /// The menu bar icon and warning line the demo scenarios are expected to produce.
    @Test func demoScenariosDriveTheMenuStatus() async {
        let recorder = Recorder()
        let plane = makeDemoEngine(.planeTwin, recorder: recorder)
        plane.refreshLink()
        await plane.scanNow()
        #expect(statusGlyph(for: plane.snapshot) == StatusGlyph(symbol: "antenna.radiowaves.left.and.right", tint: .orange))
        #expect(warningLines(for: plane.snapshot).map(\.text) == ["1 worth a look"])

        let office = makeDemoEngine(.office, recorder: recorder)
        office.refreshLink()
        await office.refreshProbes()
        await office.scanNow()
        #expect(statusGlyph(for: office.snapshot) == StatusGlyph(symbol: "antenna.radiowaves.left.and.right", tint: .normal))
        #expect(warningLines(for: office.snapshot).isEmpty)

        let off = makeDemoEngine(.wifiOff, recorder: recorder)
        off.refreshLink()
        await off.refreshProbes()
        #expect(statusGlyph(for: off.snapshot).symbol == "antenna.radiowaves.left.and.right.slash")

        let denied = makeDemoEngine(.locationDenied, recorder: recorder)
        denied.refreshLink()
        await denied.scanNow()
        #expect(!denied.snapshot.locationAuthorized)
        #expect(denied.snapshot.link != nil)
        #expect(warningLines(for: denied.snapshot).isEmpty)
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
        let clock = Clock()
        let engine = makeEngine(neighbors: neighbors, clock: clock)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        clock.date = t0 + 30   // after the settle window
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

    @Test func louderNewcomerNeedsFourCompletedScans() async {
        let wifi = FakeWiFi()
        let base = [ap("Corp", "00:0b:86:00:00:01"), ap("Corp", "00:0b:86:00:00:02")]
        wifi.scans = [.success(base), .success(base), .success(base),
                      .success(base + [ap("Corp", "00:14:6c:00:00:09", rssi: -40)])]
        let engine = makeEngine(wifi: wifi)
        engine.refreshLink()
        for _ in 0..<3 {
            await engine.scanNow()
            engine.refreshLink()   // must not hand the same scan to the monitor again
            #expect(engine.snapshot.connectedVerdict == .clear)
        }
        await engine.scanNow()
        #expect(engine.snapshot.findings.map(\.signal) == [.louderNewcomer])
        #expect(engine.snapshot.connectedVerdict == .worthALook)
    }

    @Test func newcomerDemoTurnsAmberAfterBaseline() async {
        let recorder = Recorder()
        let engine = makeDemoEngine(.newcomer, recorder: recorder)
        engine.refreshLink()
        for _ in 0..<3 {
            await engine.scanNow()
            #expect(engine.snapshot.connectedVerdict == .clear)
        }
        await engine.scanNow()
        #expect(engine.snapshot.connectedVerdict == .worthALook)
        #expect(engine.snapshot.findings.contains { $0.signal == .louderNewcomer })
        #expect(recorder.calls.count == 1)
    }

    @Test func networkSwitchDoesNotCarryGatewayBaseline() async {
        let wifi = FakeWiFi()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let recorder = Recorder()
        let engine = makeEngine(wifi: wifi, neighbors: neighbors)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func networkSwitchClearsOldConnectivity() async {
        let wifi = FakeWiFi()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01")]
        let engine = makeEngine(wifi: wifi, neighbors: neighbors)
        engine.refreshLink()
        await engine.refreshProbes()
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        engine.refreshLink()
        let c = engine.snapshot.connectivity
        #expect(c.gatewayMAC == nil)
        #expect(c.gatewayLatencyMs == nil)
        #expect(c.gatewayLossPercent == nil)
        #expect(c.dnsServers.isEmpty)
        #expect(c.dnsLatencyMs == nil)
        #expect(c.internet == .unknown)
        #expect(c.internetLatencyMs == nil)
    }

    @Test func reconnectDoesNotCarryGatewayBaseline() async {
        let wifi = FakeWiFi()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let engine = makeEngine(wifi: wifi, neighbors: neighbors)
        engine.refreshLink()
        await engine.refreshProbes()
        let corp = wifi.link
        wifi.wifiState = .notConnected
        wifi.link = nil
        engine.refreshLink()
        wifi.wifiState = .connected
        wifi.link = corp
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
    }

    @Test func networkSwitchDoesNotCarryDNSBaseline() async {
        let wifi = FakeWiFi()
        let config = FakeConfig()
        config.config = NetworkConfig(gatewayIP: nil, dnsServers: ["10.20.0.53"], ipv4: [], ipv6: [])
        let clock = Clock()
        let engine = makeEngine(wifi: wifi, config: config, clock: clock)
        engine.refreshLink()
        await engine.refreshProbes()
        clock.date = t0 + 60
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        config.config = NetworkConfig(gatewayIP: nil, dnsServers: ["192.168.1.1"], ipv4: [], ipv6: [])
        engine.refreshLink()
        clock.date = t0 + 90   // past the 10 s settle window, as with a 30 s probe interval
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
    }

    @Test func probeResultFromOldSessionIsDiscarded() async {
        let wifi = FakeWiFi()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let engine = makeEngine(wifi: wifi, neighbors: neighbors)
        engine.refreshLink()
        neighbors.duringLookup = {
            await MainActor.run {
                wifi.link = makeLink("Home", "00:14:6c:00:00:01")
                engine.refreshLink()
            }
        }
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.gatewayMAC == nil)
        neighbors.duringLookup = nil
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.gatewayMAC == mac("00:14:6c:aa:00:02"))
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
    }

    @Test func probeRequestDuringProbeRunsOnceMore() async {
        let neighbors = FakeNeighbors()
        let engine = makeEngine(neighbors: neighbors)
        engine.refreshLink()
        neighbors.duringLookup = {
            neighbors.duringLookup = nil
            // Two requests while the first probe is in flight coalesce into one rerun.
            await engine.refreshProbes()
            await engine.refreshProbes()
        }
        await engine.refreshProbes()
        #expect(neighbors.lookups == 2)
    }

    @Test func configChangeDuringProbeCommitsFreshValues() async {
        let config = FakeConfig()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let engine = makeEngine(config: config, neighbors: neighbors)
        engine.refreshLink()
        neighbors.duringLookup = {
            neighbors.duringLookup = nil
            config.config = NetworkConfig(gatewayIP: "10.0.0.1", dnsServers: ["10.0.0.53"], ipv4: ["10.0.0.7"], ipv6: [])
            await engine.refreshProbes()   // what the config-change event does
        }
        await engine.refreshProbes()
        let c = engine.snapshot.connectivity
        #expect(c.gatewayIP == "10.0.0.1")
        #expect(c.gatewayMAC == mac("00:14:6c:aa:00:02"))
        #expect(c.dnsServers == ["10.0.0.53"])
        #expect(c.ipv4 == ["10.0.0.7"])
    }

    @Test func probeWithStaleConfigCommitsNothing() async {
        let config = FakeConfig()
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:0b:86:aa:00:01"), mac("00:14:6c:aa:00:02")]
        let prober = FakeProber()
        prober.pingResults = [.timeout, .reply(2)]   // the stale probe's ping is lost
        let engine = makeEngine(config: config, neighbors: neighbors, prober: prober)
        engine.refreshLink()
        neighbors.duringLookup = {
            neighbors.duringLookup = nil
            config.config = NetworkConfig(gatewayIP: "10.0.0.1", dnsServers: ["10.0.0.53"], ipv4: [], ipv6: [])
        }
        await engine.refreshProbes()
        let c = engine.snapshot.connectivity
        #expect(neighbors.lookups == 2)
        #expect(c.gatewayIP == "10.0.0.1")
        #expect(c.gatewayMAC == mac("00:14:6c:aa:00:02"))
        #expect(c.dnsServers == ["10.0.0.53"])
        #expect(c.gatewayLossPercent == 0)
    }

    @Test func networkSwitchBeforeDHCPStaysClear() async {
        let wifi = FakeWiFi()
        let config = FakeConfig()
        let corpConfig = NetworkConfig(gatewayIP: "10.20.0.1", dnsServers: ["10.20.0.53"], ipv4: ["10.20.0.9"], ipv6: [])
        config.config = corpConfig
        let neighbors = FakeNeighbors()
        let corpRouter = mac("00:0b:86:aa:00:01"), homeRouter = mac("00:14:6c:aa:00:02")
        neighbors.answers = [corpRouter, corpRouter, homeRouter, homeRouter]
        let clock = Clock()
        let recorder = Recorder()
        let engine = makeEngine(wifi: wifi, config: config, neighbors: neighbors, clock: clock)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()

        clock.date = t0 + 60
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        engine.refreshLink()
        await engine.refreshProbes()   // DHCP not done yet: still Corp's gateway and DNS
        clock.date = t0 + 65
        config.config = NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["192.168.1.1"], ipv4: ["192.168.1.34"], ipv6: [])
        await engine.refreshProbes()
        clock.date = t0 + 100
        await engine.refreshProbes()

        #expect(engine.snapshot.connectivity.gatewayMAC == homeRouter)
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func menuToggleRestartsNoLoop() {
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        let before = engine.loopStarts
        #expect(before["scan"] == 1 && before["probes"] == 1 && before["link"] == 1)
        engine.menuOpen = true
        engine.menuOpen = false
        #expect(engine.loopStarts == before)
    }

    @Test func scanIntervalChangeRestartsOnlyScanLoop() {
        let engine = makeEngine()
        engine.start()
        defer { engine.stop() }
        var expected = engine.loopStarts
        engine.settings.scanInterval = 30
        expected["scan", default: 0] += 1
        #expect(engine.loopStarts == expected)
        engine.settings.publicIPEnabled = false
        #expect(engine.loopStarts == expected)
    }

    @Test func everyDemoScenarioBuilds() {
        for scenario in DemoScenario.allCases {
            let s = demoSources(scenario)
            #expect(s.wifi.cachedScan().allSatisfy { $0.bssid.map { !$0.isLocallyAdministered } ?? true })
        }
    }

    @Test func gatewayChangeDemoTurnsRedAfterItsSwitch() async {
        let recorder = Recorder()
        let clock = Clock()
        let engine = makeDemoEngine(.gatewayChange, recorder: recorder, clock: clock)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .clear)
        clock.date = t0 + 20   // the demo's router answers differently from 15 s on
        await engine.refreshProbes()
        #expect(engine.snapshot.connectedVerdict == .suspect)
        #expect(engine.snapshot.findings.map(\.signal) == [.gatewayChanged])
    }

    // MARK: Scan scheduling (I2, I4, M7, Task 7)

    @Test func joinRunsOneDebouncedScan() async {
        let wifi = FakeWiFi()
        wifi.wifiState = .notConnected
        wifi.link = nil
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.start()
        defer { engine.stop() }
        wifi.wifiState = .connected
        wifi.link = makeLink("Corp", "00:0b:86:00:00:01")
        wifi.emit(.ssidChanged, .bssidChanged, .linkChanged)
        await drainEvents(engine, wifi: wifi)
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 1)
        #expect(wifi.scanTimes.first == t0 + 2)
    }

    @Test func leavingRunsNoScan() async {
        let wifi = FakeWiFi()
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.start()   // connected and authorised: one scan
        defer { engine.stop() }
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 1)
        wifi.wifiState = .notConnected
        wifi.link = nil
        wifi.emit(.ssidChanged, .bssidChanged)
        await drainEvents(engine, wifi: wifi)
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 1)
    }

    @Test func wifiOffRunsNoAutomaticScanAndSetsNoError() async {
        let wifi = FakeWiFi()
        wifi.wifiState = .off
        wifi.link = nil
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.start()
        defer { engine.stop() }
        engine.requestScan()   // what the background timer does
        wifi.emit(.powerChanged, .ssidChanged, .bssidChanged)
        await drainEvents(engine, wifi: wifi)
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 0)
        #expect(engine.snapshot.scanError == nil)
    }

    @Test func locationGrantedMidRunScansOnceWithNames() async {
        let wifi = FakeWiFi()
        wifi.cached = [ap(nil, nil), ap(nil, nil, ch: 149)]
        wifi.defaultScan = [ap("Corp", "00:0b:86:00:00:01"), ap("Corp", "00:0b:86:00:00:02", ch: 149)]
        let location = FakeLocation()
        location.isAuthorized = false
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, location: location, settings: EngineSettings(scanInterval: nil),
                                clock: clock, gate: gate)
        engine.start()
        defer { engine.stop() }
        #expect(engine.snapshot.scan.allSatisfy { $0.ssid == nil })
        location.isAuthorized = true
        location.changeContinuation.yield()
        await drainEvents(engine, location: location)
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 1)
        #expect(engine.snapshot.scan.count == 2)
        #expect(engine.snapshot.scan.allSatisfy { $0.ssid == "Corp" })
    }

    @Test func requestDuringScanRunsExactlyOneMore() async {
        let wifi = FakeWiFi()
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.refreshLink()
        wifi.duringScan = {
            wifi.duringScan = nil
            await MainActor.run {
                engine.requestScan()
                engine.requestScan()
            }
            await engine.scanNow()   // never overlaps: marks the same rerun
        }
        await engine.scanNow()
        await settleScans(engine, gate)
        #expect(wifi.scanCount == 2)
        #expect(wifi.scanTimes == [t0, t0 + 10])   // the rerun keeps the 10 s spacing
    }

    @Test func automaticScanKeepsSpacingAfterScanNow() async {
        let wifi = FakeWiFi()
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.refreshLink()
        await engine.scanNow()
        engine.requestScan()
        await settleScans(engine, gate)
        #expect(wifi.scanTimes == [t0, t0 + 10])
    }

    @Test func requestsCoalesceIntoOneScan() async {
        let wifi = FakeWiFi()
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.refreshLink()
        engine.requestScan()
        engine.requestScan()
        engine.requestScan()
        await settleScans(engine, gate)
        #expect(wifi.scanTimes == [t0 + 2])
    }

    // MARK: Cached seed and detector cache (M8, M5)

    @Test func cachedSeedIsShownButRaisesNothing() async {
        let wifi = FakeWiFi()
        wifi.cached = [ap("Corp", "00:0b:86:00:00:01", ch: 36), ap("Corp", "00:0b:86:00:00:01", ch: 149)]
        let clock = Clock()
        let gate = Gate(clock: clock)
        let engine = makeEngine(wifi: wifi, settings: EngineSettings(scanInterval: nil), clock: clock, gate: gate)
        engine.start()
        defer { engine.stop() }
        #expect(engine.snapshot.scan.count == 2)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(engine.snapshot.connectedVerdict == .clear)
        await settleScans(engine, gate)
    }

    @Test func twinDetectorRunsOncePerScan() async {
        let wifi = FakeWiFi()
        wifi.scans = [.success([ap("Corp", "00:0b:86:00:00:01"), ap("Corp", "00:0b:86:00:00:02")])]
        let vendors = CountingVendors()
        let engine = makeEngine(wifi: wifi, vendors: vendors)
        engine.refreshLink()
        await engine.scanNow()
        let afterScan = vendors.lookups
        #expect(afterScan > 0)
        for _ in 0..<5 { engine.refreshLink() }
        await engine.refreshProbes()
        #expect(vendors.lookups == afterScan)
    }

    // MARK: Session boundaries (I5)

    @Test func reassociationToSameNameStartsNewSession() async {
        let wifi = FakeWiFi()
        let neighbors = FakeNeighbors()
        neighbors.answer = mac("00:14:6c:aa:00:01")
        let clock = Clock()
        let recorder = Recorder()
        let engine = makeEngine(wifi: wifi, neighbors: neighbors, settings: EngineSettings(scanInterval: nil),
                                clock: clock)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.start()
        defer { engine.stop() }
        await settleProbes(engine)
        #expect(engine.snapshot.connectivity.gatewayMAC == mac("00:14:6c:aa:00:01"))
        clock.date = t0 + 60
        neighbors.answer = mac("50:c7:bf:aa:00:02")
        wifi.emit(.ssidChanged)   // same name, no nil link read in between
        await drainEvents(engine, wifi: wifi)
        clock.date = t0 + 90
        await settleProbes(engine)
        await settleProbes(engine)
        #expect(engine.snapshot.connectivity.gatewayMAC == mac("50:c7:bf:aa:00:02"))
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func wakeStartsNewSession() async {
        let neighbors = FakeNeighbors()
        neighbors.answer = mac("00:14:6c:aa:00:01")
        let clock = Clock()
        let engine = makeEngine(neighbors: neighbors, clock: clock)
        engine.refreshLink()
        await settleProbes(engine)
        clock.date = t0 + 60
        neighbors.answer = mac("50:c7:bf:aa:00:02")
        engine.noteWake()
        clock.date = t0 + 90
        await settleProbes(engine)
        await settleProbes(engine)
        #expect(engine.snapshot.connectivity.gatewayMAC == mac("50:c7:bf:aa:00:02"))
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(engine.snapshot.findings.isEmpty)
    }

    // MARK: Probes (I3, I1, M2, Task 9)

    @Test func probesRunOnlyWhenConnected() async {
        let wifi = FakeWiFi()
        let prober = FakeProber()
        let neighbors = FakeNeighbors()
        neighbors.answer = mac("00:14:6c:aa:00:01")
        let engine = makeEngine(wifi: wifi, neighbors: neighbors, prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.gatewayIP != nil)
        let pings = prober.pingCount, checks = prober.internetCount
        wifi.wifiState = .notConnected
        await engine.refreshProbes()
        await engine.refreshPublicIP()
        #expect(prober.pingCount == pings)
        #expect(prober.internetCount == checks)
        #expect(prober.publicIPCount == 0)
        #expect(engine.snapshot.connectivity == ConnectivitySnapshot())
    }

    @Test func blockedPingIsNotLoss() async {
        let prober = FakeProber()
        prober.pingResults = [.blocked, .reply(2)]
        prober.dnsResult = .blocked
        let engine = makeEngine(prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        var c = engine.snapshot.connectivity
        #expect(c.gatewayBlocked)
        #expect(c.gatewayLatencyMs == nil)
        #expect(c.gatewayLossPercent == nil)
        #expect(c.dnsBlocked)
        #expect(c.dnsLatencyMs == nil)
        prober.dnsResult = .reply(10)
        await engine.refreshProbes()
        c = engine.snapshot.connectivity
        #expect(!c.gatewayBlocked && !c.dnsBlocked)
        #expect(c.gatewayLossPercent == 0)
    }

    @Test func timedOutPingIsLoss() async {
        let prober = FakeProber()
        prober.pingResults = [.timeout]
        let engine = makeEngine(prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.gatewayLossPercent == 100)
        #expect(!engine.snapshot.connectivity.gatewayBlocked)
    }

    @Test func pingRunsBeforeARPLookup() async {
        let log = CallLog()
        let prober = FakeProber()
        prober.log = log
        let neighbors = FakeNeighbors()
        neighbors.log = log
        let engine = makeEngine(neighbors: neighbors, prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(log.entries == ["ping", "arp"])
    }

    @Test func missingARPAnswerKeepsLastGatewayAddress() async {
        let neighbors = FakeNeighbors()
        neighbors.answers = [mac("00:14:6c:aa:00:01"), nil]
        let engine = makeEngine(neighbors: neighbors)
        engine.refreshLink()
        await engine.refreshProbes()
        await engine.refreshProbes()
        #expect(neighbors.lookups == 2)
        #expect(engine.snapshot.connectivity.gatewayMAC == mac("00:14:6c:aa:00:01"))
    }

    @Test func monitoringErrorReachesSnapshot() {
        let wifi = FakeWiFi()
        wifi.monitoringError = "Event monitoring refused"
        let engine = makeEngine(wifi: wifi)
        engine.refreshLink()
        #expect(engine.snapshot.eventMonitoringError == "Event monitoring refused")
    }
}

// MARK: - Interception checks

private let tamperedGoogle: DNSLookup = .answered(["172.19.0.1"])
private let googleTampered: DNSAnswersState =
    .tampered(name: "dns.google", address: "172.19.0.1", expected: ["8.8.8.8", "8.8.4.4"])

@MainActor
extension EngineTests {
    @Test func interceptionNotCheckedUnlessOnline() async {
        let prober = FakeProber()
        prober.internetStatus = .captivePortal
        let engine = makeEngine(prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.dnsAnswers == .notChecked)
        #expect(engine.snapshot.connectivity.https == .notChecked)
        #expect(prober.lookupCount == 0)
        #expect(prober.httpsCount == 0)
    }

    @Test func firstInterceptionCheck() async {
        let prober = FakeProber()
        let engine = makeEngine(prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.dnsAnswers == .asExpected)
        #expect(engine.snapshot.connectivity.https == .direct)
        #expect(prober.lookupCount == 3)
        #expect(prober.httpsCount == 1)
    }

    @Test func interceptionCheckCadence() async {
        let config = FakeConfig()
        let prober = FakeProber()
        let clock = Clock()
        let engine = makeEngine(config: config, prober: prober, clock: clock)
        engine.refreshLink()
        await engine.refreshProbes()
        clock.date = t0 + 10
        await engine.refreshProbes()
        #expect(prober.lookupCount == 3)
        #expect(prober.httpsCount == 1)
        #expect(engine.snapshot.connectivity.dnsAnswers == .asExpected)
        #expect(engine.snapshot.connectivity.https == .direct)
        clock.date = t0 + InterceptionCheck.interval
        await engine.refreshProbes()
        #expect(prober.lookupCount == 6)
        #expect(prober.httpsCount == 2)
        clock.date = t0 + InterceptionCheck.interval + 10
        config.config.dnsServers = ["192.168.1.53"]
        await engine.refreshProbes()
        #expect(prober.lookupCount == 9)
        #expect(prober.httpsCount == 3)
    }

    @Test func interceptionSettingOffSkipsChecks() async {
        let prober = FakeProber()
        let engine = makeEngine(prober: prober, settings: EngineSettings(interceptionChecksEnabled: false))
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(prober.lookupCount == 0)
        #expect(prober.httpsCount == 0)
        #expect(engine.snapshot.connectivity.dnsAnswers == .off)
        #expect(engine.snapshot.connectivity.https == .off)
        engine.settings.interceptionChecksEnabled = true
        #expect(engine.snapshot.connectivity.dnsAnswers == .notChecked)
        #expect(engine.snapshot.connectivity.https == .notChecked)
        await engine.refreshProbes()
        #expect(prober.lookupCount == 3)
        #expect(prober.httpsCount == 1)
        #expect(engine.snapshot.connectivity.dnsAnswers == .asExpected)
        #expect(engine.snapshot.connectivity.https == .direct)
    }

    @Test func turningInterceptionOffAndOnAgain() async {
        let prober = FakeProber()
        let clock = Clock()
        let engine = makeEngine(prober: prober, clock: clock)
        engine.refreshLink()
        await engine.refreshProbes()
        engine.settings.interceptionChecksEnabled = false
        #expect(engine.snapshot.connectivity.dnsAnswers == .off)
        #expect(engine.snapshot.connectivity.https == .off)
        clock.date = t0 + 10
        engine.settings.interceptionChecksEnabled = true
        await engine.refreshProbes()   // within the interval, but turning the checks on makes them due
        #expect(prober.lookupCount == 6)
        #expect(prober.httpsCount == 2)
        #expect(engine.snapshot.connectivity.dnsAnswers == .asExpected)
    }

    @Test func tamperedAnswerNotifiesOnce() async {
        let prober = FakeProber()
        prober.lookups["dns.google"] = tamperedGoogle
        let clock = Clock()
        let recorder = Recorder()
        let engine = makeEngine(prober: prober, clock: clock)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        let state = engine.snapshot.connectivity.dnsAnswers
        #expect(state == googleTampered)
        #expect(dnsAnswersLevel(state) == .poor)
        #expect(engine.snapshot.findings.map(\.signal) == [.dnsTampered])
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.first?.map(\.signal) == [.dnsTampered])
        for step in 1...3 {
            clock.date = t0 + Double(step) * (InterceptionCheck.interval + 1)
            await engine.refreshProbes()
        }
        #expect(prober.lookupCount == 12)
        #expect(engine.snapshot.connectivity.dnsAnswers == googleTampered)
        #expect(recorder.calls.count == 1)
    }

    @Test func handSetPrivateServerIsFilteredByIt() async {
        let config = FakeConfig()
        config.config = NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["192.168.1.2"], ipv4: ["192.168.1.20"],
                                      ipv6: [], dnsServersSetByHand: true)
        let prober = FakeProber()
        prober.lookups["dns.google"] = tamperedGoogle
        let recorder = Recorder()
        let engine = makeEngine(config: config, prober: prober)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.dnsAnswers == .filteredByYourServer(name: "dns.google", address: "172.19.0.1"))
        #expect(engine.snapshot.findings.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func handSetPublicServerIsStillTampered() async {
        let config = FakeConfig()
        config.config = NetworkConfig(gatewayIP: "192.168.1.1", dnsServers: ["1.1.1.1"], ipv4: ["192.168.1.20"],
                                      ipv6: [], dnsServersSetByHand: true)
        let prober = FakeProber()
        prober.lookups["dns.google"] = tamperedGoogle
        let engine = makeEngine(config: config, prober: prober)
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.dnsAnswers == googleTampered)
        #expect(engine.snapshot.findings.map(\.signal) == [.dnsTampered])
    }

    @Test func decryptableHTTPSRaisesNothing() async {
        let prober = FakeProber()
        prober.httpsResult = .decryptable(root: "X")
        let recorder = Recorder()
        let engine = makeEngine(prober: prober)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.https == .decryptable(root: "X"))
        #expect(engine.snapshot.findings.isEmpty)
        #expect(engine.snapshot.connectedVerdict == .clear)
        #expect(recorder.calls.isEmpty)
    }

    @Test func sessionChangeDuringCheckDropsIt() async {
        let wifi = FakeWiFi()
        let prober = FakeProber()
        prober.lookups["dns.google"] = tamperedGoogle
        let clock = Clock()
        let hold = Gate(clock: clock)
        prober.duringLookup = { _ = await hold.sleep(0) }
        let recorder = Recorder()
        let engine = makeEngine(wifi: wifi, prober: prober, clock: clock)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        let probe = Task { await engine.refreshProbes() }
        for _ in 0..<100_000 where hold.sleeps.count < 3 { await Task.yield() }
        #expect(hold.sleeps.count == 3)   // all three lookups are held in flight
        wifi.link = makeLink("Home", "00:14:6c:00:00:01")
        engine.refreshLink()
        hold.open()
        await probe.value
        #expect(engine.snapshot.connectivity.dnsAnswers == .notChecked)
        #expect(engine.snapshot.connectivity.https == .notChecked)
        #expect(!engine.snapshot.findings.contains { $0.signal == .dnsTampered })
        #expect(recorder.calls.isEmpty)
        await engine.refreshProbes()
        #expect(prober.lookupCount == 6)
        #expect(engine.snapshot.connectivity.dnsAnswers == googleTampered)
        #expect(recorder.calls.flatMap { $0 }.map(\.ssid) == ["Home"])
    }

    @Test func tamperedWithoutLocationRaisesNothing() async {
        let wifi = FakeWiFi()
        wifi.link = makeLink(nil, nil)
        let location = FakeLocation()
        location.isAuthorized = false
        let prober = FakeProber()
        prober.lookups["dns.google"] = tamperedGoogle
        let recorder = Recorder()
        let engine = makeEngine(wifi: wifi, prober: prober, location: location)
        engine.onNewFindings = { recorder.calls.append($0) }
        engine.refreshLink()
        await engine.refreshProbes()
        #expect(engine.snapshot.connectivity.dnsAnswers == googleTampered)
        #expect(engine.snapshot.findings.isEmpty)
        #expect(recorder.calls.isEmpty)
    }

    @Test func interceptionDemoScenarios() async {
        let recorder = Recorder()
        let tampered = makeDemoEngine(.dnsTampered, recorder: recorder)
        tampered.refreshLink()
        await tampered.refreshProbes()
        #expect(tampered.snapshot.connectivity.dnsAnswers == googleTampered)
        #expect(tampered.snapshot.findings.map(\.signal) == [.dnsTampered])
        #expect(tampered.snapshot.connectedVerdict == .suspect)

        let filtered = makeDemoEngine(.dnsFiltered, recorder: recorder)
        filtered.refreshLink()
        await filtered.refreshProbes()
        #expect(filtered.snapshot.connectivity.dnsAnswers == .filtered)
        #expect(filtered.snapshot.findings.isEmpty)

        let rewritten = makeDemoEngine(.dnsRewritten, recorder: recorder)
        rewritten.refreshLink()
        await rewritten.refreshProbes()
        #expect(rewritten.snapshot.connectivity.dnsAnswers == .rewritten(address: "10.20.0.80"))
        #expect(rewritten.snapshot.findings.isEmpty)

        let decryptable = makeDemoEngine(.httpsDecryptable, recorder: recorder)
        decryptable.refreshLink()
        await decryptable.refreshProbes()
        #expect(decryptable.snapshot.connectivity.https == .decryptable(root: "Demo Inspection CA"))
        #expect(decryptable.snapshot.connectivity.dnsAnswers == .asExpected)
        #expect(decryptable.snapshot.findings.isEmpty)

        let office = makeDemoEngine(.office, recorder: recorder)
        office.refreshLink()
        await office.refreshProbes()
        #expect(office.snapshot.connectivity.dnsAnswers == .asExpected)
        #expect(office.snapshot.connectivity.https == .direct)
        #expect(office.snapshot.findings.isEmpty)

        #expect(recorder.calls.flatMap { $0 }.map(\.signal) == [.dnsTampered])
    }
}
