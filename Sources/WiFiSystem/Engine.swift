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
            if settings.scanInterval != oldValue.scanInterval, tasks.isRunning { startTimers() }
        }
    }

    /// Setting true refreshes the public IP; opening or closing the menu also changes the refresh cadence.
    public var menuOpen = false {
        didSet {
            guard menuOpen != oldValue else { return }
            if tasks.isRunning { startTimers() }
            if menuOpen { Task { await refreshPublicIP() } }
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
    @ObservationIgnored private var sessionID = 0
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var probing = false
    @ObservationIgnored private var fetchingPublicIP = false
    @ObservationIgnored private let tasks = TaskBag()

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
        startTimers()
        startEventLoops()
    }

    /// Cancels every timer and event loop.
    public func stop() {
        tasks.cancelAll()
    }

    private func startTimers() {
        tasks.replace("link", with: Task { [weak self] in
            while true {
                guard let interval = self?.linkTick() else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        })
        tasks.replace("probes", with: Task { [weak self] in
            while true {
                guard let interval = await self?.probeTick() else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        })
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
                self.refreshLink()
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
                self.refreshLink()
            }
        })
    }

    private func linkTick() -> TimeInterval {
        refreshLink()
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

    /// Reads the IP configuration and probes the gateway, DNS and internet.
    public func refreshProbes() async {
        guard !probing else { return }
        probing = true
        defer { probing = false }

        let current = config.current()
        var gatewayMAC: MACAddress?
        var gatewayLatency: Double?
        var gatewayLoss: Int?
        if let gateway = current.gatewayIP {
            gatewayMAC = await neighbors.hardwareAddress(forIPv4: gateway)
            gatewayLatency = await prober.ping(gateway)
            lossWindow.record(success: gatewayLatency != nil)
            gatewayLoss = lossWindow.lossPercent
        }
        var dnsLatency: Double?
        if let server = current.dnsServers.first {
            dnsLatency = await prober.dnsLatency(server: server)
        }
        let internet = await prober.internetCheck()

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
    }

    /// Fetches the public IP unless disabled or already known for this session.
    public func refreshPublicIP() async {
        guard settings.publicIPEnabled, snapshot.connectivity.publicIP == nil, !fetchingPublicIP else { return }
        fetchingPublicIP = true
        defer { fetchingPublicIP = false }
        let session = sessionID
        let address = await prober.publicIP()
        // Drop a stale answer if the session changed or the setting was turned off meanwhile.
        guard session == sessionID, settings.publicIPEnabled else { return }
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
        var connection: ConnectionState?
        if snapshot.locationAuthorized, let link = snapshot.link, let name = link.ssid, let address = link.bssid {
            connection = ConnectionState(ssid: name, bssid: address, rssi: link.rssi,
                                         gatewayMAC: snapshot.connectivity.gatewayMAC,
                                         dnsServers: snapshot.connectivity.dnsServers)
        }
        let siblingFindings = detector.findings(in: snapshot.scan)
        let connectedFindings = monitor.update(
            connection: connection, scan: completedScan,
            siblingFindings: siblingFindings.filter { $0.ssid == connection?.ssid },
            now: now())

        if monitor.sessionID != sessionID {
            sessionID = monitor.sessionID
            snapshot.connectivity.publicIP = nil
            lossWindow = LossWindow()
        }

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

/// Owns the Engine's long-running tasks and cancels them when replaced, stopped or released.
private final class TaskBag {
    var isRunning = false
    private var tasks: [String: Task<Void, Never>] = [:]

    func replace(_ key: String, with task: Task<Void, Never>?) {
        tasks[key]?.cancel()
        tasks[key] = task
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
