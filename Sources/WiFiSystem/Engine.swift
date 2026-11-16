import Foundation
import Observation
import WiFiCore

public struct EngineSettings: Sendable, Equatable {
    /// Seconds between background scans; nil turns background scanning off.
    public var scanInterval: TimeInterval?
    public var publicIPEnabled: Bool

    public init(scanInterval: TimeInterval? = 60, publicIPEnabled: Bool = true) {
        self.scanInterval = scanInterval
        self.publicIPEnabled = publicIPEnabled
    }
}

/// Drives every data source and keeps one `Snapshot` up to date for the UI.
@MainActor @Observable
public final class Engine {
    public private(set) var snapshot: Snapshot = .empty

    public var settings: EngineSettings {
        didSet {
            if !settings.publicIPEnabled { snapshot.connectivity.publicIP = nil }
            if settings.scanInterval != oldValue.scanInterval, tasks.isRunning { startScanLoop() }
        }
    }

    /// Setting true refreshes the public IP and cuts short the link and probe waits, so the faster
    /// menu-open cadence applies at once. It never restarts a loop, cancels a refresh or touches the scan countdown.
    public var menuOpen = false {
        didSet {
            guard menuOpen, !oldValue else { return }
            linkNap.wake()
            probeNap.wake()
            Task { await refreshPublicIP() }
        }
    }

    /// Called with findings that deserve a notification, at most once per finding per session.
    @ObservationIgnored public var onNewFindings: (([Finding]) -> Void)?

    @ObservationIgnored private let wifi: WiFiSource
    @ObservationIgnored private let config: NetworkConfigSource
    @ObservationIgnored private let neighbors: NeighborSource
    @ObservationIgnored private let prober: Prober
    @ObservationIgnored private let location: LocationAuthorizing
    @ObservationIgnored private let detector: TwinDetector
    @ObservationIgnored private let now: () -> Date

    @ObservationIgnored private var monitor = ConnectionMonitor()
    @ObservationIgnored private var ledger = NotificationLedger()
    @ObservationIgnored private var lossWindow = LossWindow()
    /// The network name of the current session as the Engine sees it; nil when there is none.
    @ObservationIgnored private var sessionName: String?
    /// Changes whenever a session ends or starts; probe and public-IP results from an older epoch are dropped.
    @ObservationIgnored private var connectionEpoch = 0
    /// True from a session change until a probe for the new session completes.
    @ObservationIgnored private var probesStale = false
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var probing = false
    /// A probe was asked for while one was in flight.
    @ObservationIgnored private var probeRequested = false
    @ObservationIgnored private var fetchingPublicIP = false
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private let linkNap = Nap()
    @ObservationIgnored private let probeNap = Nap()

    public init(wifi: WiFiSource, config: NetworkConfigSource, neighbors: NeighborSource, prober: Prober,
                location: LocationAuthorizing, vendors: VendorLookup, settings: EngineSettings,
                now: @escaping () -> Date = Date.init) {
        self.wifi = wifi
        self.config = config
        self.neighbors = neighbors
        self.prober = prober
        self.location = location
        self.detector = TwinDetector(vendors: vendors)
        self.settings = settings
        self.now = now
    }

    // MARK: Lifecycle

    /// Requests Location if undetermined, seeds the scan from the system cache, then starts timers and event loops.
    public func start() {
        stop()
        if !location.isDetermined { location.request() }
        snapshot.scan = wifi.cachedScan()
        refreshLink()
        tasks.isRunning = true
        startLinkAndProbeLoops()
        startScanLoop()
        startEventLoops()
    }

    /// Cancels every timer and event loop.
    public func stop() {
        tasks.cancelAll()
    }

    /// How many times each loop has been started.
    var loopStarts: [String: Int] { tasks.starts }

    /// The link and probe loops re-read their cadence after every tick, so they are started only once.
    private func startLinkAndProbeLoops() {
        let linkNap = linkNap
        tasks.replace("link", with: Task { [weak self] in
            while true {
                guard let interval = self?.linkTick() else { return }
                guard await linkNap.sleep(interval) else { return }
            }
        })
        let probeNap = probeNap
        tasks.replace("probes", with: Task { [weak self] in
            while true {
                guard let interval = await self?.probeTick() else { return }
                guard await probeNap.sleep(interval) else { return }
            }
        })
    }

    /// Restarted only when `settings.scanInterval` changes.
    private func startScanLoop() {
        guard let interval = settings.scanInterval else {
            tasks.replace("scan", with: nil)
            return
        }
        tasks.replace("scan", with: Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
                guard let self else { return }
                await self.scanNow()
            }
        })
    }

    private func startEventLoops() {
        let events = wifi.events
        tasks.replace("wifiEvents", with: Task { [weak self] in
            for await event in events {
                guard let self else { return }
                _ = self.linkTick()
                switch event {
                case .ssidChanged, .bssidChanged: await self.scanNow()
                case .powerChanged, .linkChanged: break
                }
            }
        })
        let configChanges = config.changes
        tasks.replace("configChanges", with: Task { [weak self] in
            for await _ in configChanges {
                guard let self else { return }
                await self.refreshProbes()
            }
        })
        let locationChanges = location.changes
        tasks.replace("locationChanges", with: Task { [weak self] in
            for await _ in locationChanges {
                guard let self else { return }
                _ = self.linkTick()
            }
        })
    }

    /// Refreshes the link and, after a session change, starts a probe for the new network without waiting for it.
    private func linkTick() -> TimeInterval {
        refreshLink()
        if probesStale { Task { await refreshProbes() } }
        return Cadence.linkInterval(menuOpen: menuOpen)
    }

    private func probeTick() async -> TimeInterval {
        await refreshProbes()
        return Cadence.probeInterval(menuOpen: menuOpen)
    }

    // MARK: Refreshes

    /// Reads the link, the Wi-Fi state and the Location flag.
    public func refreshLink() {
        snapshot.state = wifi.state()
        snapshot.link = wifi.currentLink()
        snapshot.locationAuthorized = location.isAuthorized
        recompute(completedScan: nil)
    }

    /// Reads the IP configuration and probes the gateway, DNS and internet. A call that arrives while a probe is
    /// in flight is not lost: any number of them coalesce into one more probe after the current one finishes.
    public func refreshProbes() async {
        guard !probing else {
            probeRequested = true
            return
        }
        probing = true
        defer { probing = false }

        var retriedStaleConfig = false
        repeat {
            probeRequested = false
            if await probeOnce() == .configChanged, !retriedStaleConfig {
                retriedStaleConfig = true
                probeRequested = true
            }
        } while probeRequested
    }

    private enum ProbeOutcome { case committed, sessionChanged, configChanged }

    private func probeOnce() async -> ProbeOutcome {
        let epoch = connectionEpoch
        let current = config.current()
        var gatewayMAC: MACAddress?
        var gatewayLatency: Double?
        if let gateway = current.gatewayIP {
            gatewayMAC = await neighbors.hardwareAddress(forIPv4: gateway)
            gatewayLatency = await prober.ping(gateway)
        }
        var dnsLatency: Double?
        if let server = current.dnsServers.first {
            dnsLatency = await prober.dnsLatency(server: server)
        }
        let internet = await prober.internetCheck()

        // Results measured against a previous network or an outdated configuration are discarded whole,
        // loss sample included.
        guard epoch == connectionEpoch else { return .sessionChanged }
        guard config.current() == current else { return .configChanged }
        probesStale = false
        var gatewayLoss: Int?
        if current.gatewayIP != nil {
            lossWindow.record(success: gatewayLatency != nil)
            gatewayLoss = lossWindow.lossPercent
        }

        snapshot.connectivity.gatewayIP = current.gatewayIP
        snapshot.connectivity.gatewayMAC = gatewayMAC
        snapshot.connectivity.gatewayLatencyMs = gatewayLatency
        snapshot.connectivity.gatewayLossPercent = gatewayLoss
        snapshot.connectivity.dnsServers = current.dnsServers
        snapshot.connectivity.dnsLatencyMs = dnsLatency
        snapshot.connectivity.internet = internet.status
        snapshot.connectivity.internetLatencyMs = internet.latencyMs
        snapshot.connectivity.ipv4 = current.ipv4
        snapshot.connectivity.ipv6 = current.ipv6
        recompute(completedScan: nil)
        return .committed
    }

    /// Fetches the public IP unless disabled or already known for this session.
    public func refreshPublicIP() async {
        guard settings.publicIPEnabled, snapshot.connectivity.publicIP == nil, !fetchingPublicIP else { return }
        fetchingPublicIP = true
        defer { fetchingPublicIP = false }
        let epoch = connectionEpoch
        let address = await prober.publicIP()
        // Drop a stale answer if the session changed or the setting was turned off meanwhile.
        guard epoch == connectionEpoch, settings.publicIPEnabled else { return }
        snapshot.connectivity.publicIP = address
        recompute(completedScan: nil)
    }

    /// Runs a full scan, then re-evaluates findings. A failed scan keeps the previous results.
    public func scanNow() async {
        guard !scanning else { return }
        scanning = true
        defer { scanning = false }
        do {
            let result = try await wifi.scan()
            snapshot.scan = result
            snapshot.scanTime = now()
            snapshot.scanError = nil
            recompute(completedScan: result)
        } catch {
            snapshot.scanError = error.localizedDescription
            recompute(completedScan: nil)
        }
    }

    // MARK: Findings

    /// completedScan: the result of a full scan that just finished, else nil.
    private func recompute(completedScan: [AccessPoint]?) {
        // Mirrors ConnectionMonitor's session rule (nil ends a session, a new name starts one), but runs first,
        // so values measured on the previous network never become the new session's baseline.
        let link = snapshot.locationAuthorized ? snapshot.link : nil
        let name = link?.bssid == nil ? nil : link?.ssid
        if name != sessionName {
            sessionName = name
            connectionEpoch += 1
            snapshot.connectivity = ConnectivitySnapshot()
            lossWindow = LossWindow()
            probesStale = true
        }

        var connection: ConnectionState?
        if let link, let name, let address = link.bssid {
            connection = ConnectionState(ssid: name, bssid: address, rssi: link.rssi,
                                         gatewayMAC: snapshot.connectivity.gatewayMAC,
                                         dnsServers: snapshot.connectivity.dnsServers)
        }
        let siblingFindings = detector.findings(in: snapshot.scan)
        let connectedFindings = monitor.update(
            connection: connection, scan: completedScan,
            siblingFindings: siblingFindings.filter { $0.ssid == connection?.ssid },
            now: now())

        guard snapshot.locationAuthorized else {
            snapshot.findings = []
            snapshot.connectedVerdict = .clear
            return
        }
        let findings = siblingFindings + connectedFindings
        snapshot.findings = findings
        snapshot.connectedVerdict = snapshot.link?.ssid.map { networkVerdict(ssid: $0, findings: findings) } ?? .clear

        let fresh = ledger.pending(findings: findings, connectedSSID: connection?.ssid, sessionID: monitor.sessionID)
        if !fresh.isEmpty { onNewFindings?(fresh) }
    }
}

/// A sleep that `wake()` can cut short without cancelling the task that sleeps.
@MainActor
private final class Nap {
    private var sleeper: Task<Void, Never>?

    /// Sleeps for `seconds` or until woken. Returns false when the calling task was cancelled.
    func sleep(_ seconds: TimeInterval) async -> Bool {
        let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(seconds)) }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        if self.sleeper == sleeper { self.sleeper = nil }
        return !Task.isCancelled
    }

    func wake() { sleeper?.cancel() }
}

/// Owns the Engine's long-running tasks and cancels them when replaced, stopped or released.
private final class TaskBag {
    var isRunning = false
    private var tasks: [String: Task<Void, Never>] = [:]
    /// How many times each loop has been started; lets tests check which changes restart which loops.
    private(set) var starts: [String: Int] = [:]

    func replace(_ key: String, with task: Task<Void, Never>?) {
        tasks[key]?.cancel()
        tasks[key] = task
        if task != nil { starts[key, default: 0] += 1 }
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
        isRunning = false
    }

    deinit {
        for task in tasks.values { task.cancel() }
    }
}
