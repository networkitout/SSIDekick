import Foundation
import Observation
import WiFiCore

public struct EngineSettings: Sendable, Equatable {
    /// Seconds between background scans; nil turns background scanning off.
    public var scanInterval: TimeInterval?
    public var publicIPEnabled: Bool
    /// The DNS answers and HTTPS checks.
    public var interceptionChecksEnabled: Bool

    public init(scanInterval: TimeInterval? = 60, publicIPEnabled: Bool = true, interceptionChecksEnabled: Bool = true) {
        self.scanInterval = scanInterval
        self.publicIPEnabled = publicIPEnabled
        self.interceptionChecksEnabled = interceptionChecksEnabled
    }
}

/// Drives every data source and keeps one `Snapshot` up to date for the UI.
@MainActor @Observable
public final class Engine {
    public private(set) var snapshot: Snapshot = .empty

    public var settings: EngineSettings {
        didSet {
            if !settings.publicIPEnabled { snapshot.connectivity.publicIP = nil }
            if settings.interceptionChecksEnabled != oldValue.interceptionChecksEnabled { interceptionSettingChanged() }
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
    /// Waits the given seconds; false when the waiting task was cancelled. Injected so tests need no wall clock.
    @ObservationIgnored private let sleep: (TimeInterval) async -> Bool

    @ObservationIgnored private var monitor = ConnectionMonitor()
    /// Sibling findings of the last completed full scan; recomputed only when a scan completes.
    @ObservationIgnored private var siblingFindings: [Finding] = []
    @ObservationIgnored private var scheduler = ScanScheduler()
    /// Location authorisation as last seen by the Location event loop. Kept apart from the snapshot, which the link
    /// loop may refresh first, so a grant is never missed.
    @ObservationIgnored private var locationWasAuthorized = false
    @ObservationIgnored private var ledger = NotificationLedger()
    @ObservationIgnored private var lossWindow = LossWindow()
    /// The network name of the current session as the Engine sees it; nil when there is none.
    @ObservationIgnored private var sessionName: String?
    /// Changes whenever a session ends or starts; probe and public-IP results from an older epoch are dropped.
    @ObservationIgnored private var connectionEpoch = 0
    /// True from a session change until a probe for the new session completes.
    @ObservationIgnored private var probesStale = false
    /// True while a full scan runs; the scan window disables "Scan now" meanwhile.
    public private(set) var isScanning = false
    @ObservationIgnored private var probing = false
    /// A probe was asked for while one was in flight.
    @ObservationIgnored private var probeRequested = false
    @ObservationIgnored private var fetchingPublicIP = false
    /// When the interception checks last completed and were committed in this session; nil when they have not.
    @ObservationIgnored private var lastInterceptionCheck: Date?
    /// The DNS servers the last committed interception check ran against.
    @ObservationIgnored private var interceptionCheckServers: [String] = []
    /// The access point the last committed interception check ran on; nil when its address was not known.
    @ObservationIgnored private var interceptionCheckBSSID: MACAddress?
    /// After a roam to another access point of the same network, the checks are due again once the last one is
    /// this old.
    private static let roamRecheckAge: TimeInterval = 30
    @ObservationIgnored private let tasks = TaskBag()
    @ObservationIgnored private let linkNap = Nap()
    @ObservationIgnored private let probeNap = Nap()

    public init(wifi: WiFiSource, config: NetworkConfigSource, neighbors: NeighborSource, prober: Prober,
                location: LocationAuthorizing, vendors: VendorLookup, settings: EngineSettings,
                now: @escaping () -> Date = Date.init,
                sleep: @escaping (TimeInterval) async -> Bool = { seconds in
                    (try? await Task.sleep(for: .seconds(seconds))) != nil
                }) {
        self.wifi = wifi
        self.config = config
        self.neighbors = neighbors
        self.prober = prober
        self.location = location
        self.detector = TwinDetector(vendors: vendors)
        self.settings = settings
        self.now = now
        self.sleep = sleep
        snapshot.connectivity = emptyConnectivity
    }

    // MARK: Lifecycle

    /// Requests Location if undetermined, seeds the scan from the system cache (for display only: it raises no
    /// findings), then starts timers and event loops, and asks for a first scan when connected with Location allowed.
    public func start() {
        stop()
        if !location.isDetermined { location.request() }
        snapshot.scan = wifi.cachedScan()
        refreshLink()
        tasks.isRunning = true
        locationWasAuthorized = location.isAuthorized
        startLinkAndProbeLoops()
        startScanLoop()
        startEventLoops()
        if snapshot.state == .connected, location.isAuthorized { requestScan() }
    }

    /// Cancels every timer and event loop, and any pending automatic scan.
    public func stop() {
        tasks.cancelAll()
        scheduler.cancelPending()
    }

    /// How many times each loop has been started.
    var loopStarts: [String: Int] { tasks.starts }
    /// Test hook: the task currently registered under `key`.
    func loopTask(_ key: String) -> Task<Void, Never>? { tasks.task(key) }
    /// Test hook: the task that runs the next automatic scan, if one was armed.
    var armedScanTask: Task<Void, Never>? { tasks.task("scanRequest") }
    /// Test hook: a probe round is running.
    var isProbing: Bool { probing }
    /// Test hook: the connection epoch, which changes whenever a session ends or starts.
    var epoch: Int { connectionEpoch }

    /// Ends the current session after the Mac wakes, so a network joined meanwhile starts with fresh baselines.
    public func noteWake() {
        endSession()
        _ = linkTick()
    }

    /// Asks for an automatic scan through the scheduler: debounced, spaced from the previous scan, skipped when
    /// Wi-Fi is not connected at the time it falls due, and rerun once if a scan is in flight.
    func requestScan() {
        if scheduler.request(now: now()) { armScan() }
    }

    /// Starts (or restarts) the timer for the pending automatic scan.
    private func armScan() {
        guard let due = scheduler.dueDate else { return }
        let sleep = self.sleep
        let wait = due.timeIntervalSince(now())
        tasks.replace("scanRequest", with: Task { [weak self] in
            if wait > 0 { guard await sleep(wait) else { return } }
            await self?.runRequestedScan()
        })
    }

    private func runRequestedScan() async {
        guard let due = scheduler.dueDate, !scheduler.isScanning else { return }
        if due > now() {
            armScan()
            return
        }
        guard wifi.state() == .connected else {
            scheduler.cancelPending()
            return
        }
        await performScan()
    }

    /// Ends the current session: the next link read starts a new one, even under the same network name.
    private func endSession() {
        monitor.reset()
        sessionName = nil
        connectionEpoch += 1
        resetConnectivity()
        probesStale = true
    }

    /// Connectivity with nothing measured yet. The interception rows read "off" while the setting is off, else
    /// "not checked".
    private var emptyConnectivity: ConnectivitySnapshot {
        var empty = ConnectivitySnapshot()
        if !settings.interceptionChecksEnabled {
            empty.dnsAnswers = .off
            empty.https = .off
        }
        return empty
    }

    /// Clears the measured connectivity, the loss window and the interception check schedule.
    private func resetConnectivity() {
        snapshot.connectivity = emptyConnectivity
        lossWindow = LossWindow()
        clearInterceptionSchedule()
        interceptionCheckServers = []
    }

    /// Makes the interception checks due at the next round.
    private func clearInterceptionSchedule() {
        lastInterceptionCheck = nil
        interceptionCheckBSSID = nil
    }

    /// Off shows both rows as off at once. On shows them as not checked and makes the checks due, then cuts the
    /// probe wait short (or asks for one more probe when one is in flight) so they run without waiting a cadence.
    private func interceptionSettingChanged() {
        if settings.interceptionChecksEnabled {
            snapshot.connectivity.dnsAnswers = .notChecked
            snapshot.connectivity.https = .notChecked
            clearInterceptionSchedule()
            if probing { probeRequested = true }
            probeNap.wake()
        } else {
            snapshot.connectivity.dnsAnswers = .off
            snapshot.connectivity.https = .off
        }
    }

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
                self.requestScan()
            }
        })
    }

    private func startEventLoops() {
        let events = wifi.events
        tasks.replace("wifiEvents", with: Task { [weak self] in
            for await event in events {
                guard let self else { return }
                self.handle(event)
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
                let authorized = self.location.isAuthorized
                if authorized, !self.locationWasAuthorized { self.requestScan() }
                self.locationWasAuthorized = authorized
            }
        })
    }

    /// A name change is a session boundary even when the name stays the same (re-association), so it ends the
    /// session before the link is read. Joining or roaming asks for a scan; leaving does not.
    private func handle(_ event: WiFiEvent) {
        if event == .ssidChanged { endSession() }
        _ = linkTick()
        switch event {
        case .ssidChanged, .bssidChanged:
            if snapshot.state == .connected, snapshot.link != nil { requestScan() }
        case .powerChanged, .linkChanged:
            break
        }
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
        snapshot.eventMonitoringError = wifi.monitoringError
        recompute(completedScan: nil)
    }

    /// Reads the IP configuration and probes the gateway, DNS and internet, then runs the interception checks when
    /// they are due. A call that arrives while a probe is in flight is not lost: any number of them coalesce into
    /// one more probe after the current one finishes.
    /// Nothing is probed unless Wi-Fi is connected; otherwise the connectivity values are cleared.
    public func refreshProbes() async {
        guard wifi.state() == .connected else {
            if snapshot.connectivity != emptyConnectivity {
                connectionEpoch += 1   // drops any probe still in flight
                resetConnectivity()
            }
            return
        }
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

    /// What a probe round does about the DNS answers and HTTPS checks.
    private enum InterceptionOutcome {
        /// The setting was off when the round started.
        case off
        /// The captive check over Wi-Fi was not online: nothing else was sent and both rows read "not checked".
        case notOnline
        /// The last committed check is recent and used the same DNS servers and access point; the rows keep their
        /// values.
        case notDue
        case checked(dns: DNSAnswersState, https: HTTPSState)
    }

    /// Due when no check has been committed this session, the last one is `InterceptionCheck.interval` old, the
    /// DNS servers changed since it ran, or Wi-Fi roamed to another access point (`bssid`, when known) and the last
    /// check is `roamRecheckAge` old.
    private func interceptionCheckDue(servers: [String], bssid: MACAddress?) -> Bool {
        guard let lastInterceptionCheck else { return true }
        let age = now().timeIntervalSince(lastInterceptionCheck)
        if age >= InterceptionCheck.interval || servers != interceptionCheckServers { return true }
        if let bssid, bssid != interceptionCheckBSSID, age >= Self.roamRecheckAge { return true }
        return false
    }

    /// `wifiCaptive`: the round's captive check over Wi-Fi, nil when the setting was off at the start of the round.
    private func interceptionOutcome(_ current: NetworkConfig, wifiCaptive: InternetStatus?,
                                     bssid: MACAddress?) async -> InterceptionOutcome {
        guard settings.interceptionChecksEnabled, let wifiCaptive else { return .off }
        guard wifiCaptive == .online else { return .notOnline }
        guard interceptionCheckDue(servers: current.dnsServers, bssid: bssid) else { return .notDue }
        let prober = self.prober
        async let https = prober.httpsCheck()
        guard let server = current.dnsServers.first else { return .checked(dns: .notChecked, https: await https) }
        let names = InterceptionCheck.knownNames.map(\.name) + [madeUpName()]
        let answers = await withTaskGroup(of: (Int, DNSLookup).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask { (index, await prober.dnsLookup(name: name, server: server)) }
            }
            var answers = [DNSLookup](repeating: .failed, count: names.count)
            for await (index, answer) in group { answers[index] = answer }
            return answers
        }
        let known = zip(names, answers).dropLast().map { (name: $0.0, lookup: $0.1) }
        let dns = classifyDNS(known: known, madeUp: answers[answers.count - 1],
                              handSetPrivateServer: current.dnsServersSetByHand && isPrivateAddress(server))
        return .checked(dns: dns, https: await https)
    }

    /// Commits a round's interception outcome, reading the setting as it is now: it may have changed mid-round.
    private func commitInterception(_ outcome: InterceptionOutcome, servers: [String], bssid: MACAddress?) {
        guard settings.interceptionChecksEnabled else {
            snapshot.connectivity.dnsAnswers = .off
            snapshot.connectivity.https = .off
            return
        }
        switch outcome {
        case .off, .notDue:
            break   // .off: turned on mid-round; the rows already read "not checked" and another round is due
        case .notOnline:
            snapshot.connectivity.dnsAnswers = .notChecked
            snapshot.connectivity.https = .notChecked
            clearInterceptionSchedule()   // check again as soon as the captive check is online
        case .checked(let dns, let https):
            snapshot.connectivity.dnsAnswers = dns
            snapshot.connectivity.https = https
            lastInterceptionCheck = now()
            interceptionCheckServers = servers
            interceptionCheckBSSID = bssid
        }
    }

    private func probeOnce() async -> ProbeOutcome {
        let epoch = connectionEpoch
        let current = config.current()
        var gatewayMAC: MACAddress?
        var gatewayPing: PingResult?
        if let gateway = current.gatewayIP {
            // The ping first: it makes the system resolve the router's hardware address before ARP is read.
            gatewayPing = await prober.ping(gateway)
            gatewayMAC = await neighbors.hardwareAddress(forIPv4: gateway)
        }
        var dnsResult: PingResult?
        if let server = current.dnsServers.first {
            dnsResult = await prober.dnsLatency(server: server)
        }
        // The default-route check feeds the Internet row. The interception checks are gated on the same check sent
        // over Wi-Fi, run alongside it every round while the setting is on, so a Wi-Fi network that turns captive
        // reads "not checked" within one round whatever the default route says.
        let bssid = snapshot.link?.bssid
        let prober = self.prober
        let checksOn = settings.interceptionChecksEnabled
        async let wifiCaptive: InternetStatus? = checksOn ? prober.wifiCaptiveCheck() : nil
        let internet = await prober.internetCheck()
        let interception = await interceptionOutcome(current, wifiCaptive: await wifiCaptive, bssid: bssid)

        // Results measured against a previous network or an outdated configuration are discarded whole,
        // loss sample included.
        guard epoch == connectionEpoch else { return .sessionChanged }
        guard config.current() == current else { return .configChanged }
        probesStale = false
        // A ping that could not be sent says nothing about loss.
        if let gatewayPing, gatewayPing != .blocked {
            lossWindow.record(success: gatewayPing.latencyMs != nil)
        }
        let gatewayLoss = current.gatewayIP == nil ? nil : lossWindow.lossPercent
        // A missing ARP answer keeps the last good address for the same router in this session.
        let previous = snapshot.connectivity
        if gatewayMAC == nil, previous.gatewayIP == current.gatewayIP { gatewayMAC = previous.gatewayMAC }

        snapshot.connectivity.gatewayIP = current.gatewayIP
        snapshot.connectivity.gatewayMAC = gatewayMAC
        snapshot.connectivity.gatewayLatencyMs = gatewayPing?.latencyMs
        snapshot.connectivity.gatewayLossPercent = gatewayLoss
        snapshot.connectivity.gatewayBlocked = gatewayPing == .blocked
        snapshot.connectivity.dnsServers = current.dnsServers
        snapshot.connectivity.dnsLatencyMs = dnsResult?.latencyMs
        snapshot.connectivity.dnsBlocked = dnsResult == .blocked
        snapshot.connectivity.internet = internet.status
        snapshot.connectivity.internetLatencyMs = internet.latencyMs
        snapshot.connectivity.ipv4 = current.ipv4
        snapshot.connectivity.ipv6 = current.ipv6
        commitInterception(interception, servers: current.dnsServers, bssid: bssid)
        recompute(completedScan: nil)
        return .committed
    }

    /// Fetches the public IP unless disabled or already known for this session.
    public func refreshPublicIP() async {
        guard wifi.state() == .connected, settings.publicIPEnabled, snapshot.connectivity.publicIP == nil, !fetchingPublicIP else { return }
        fetchingPublicIP = true
        defer { fetchingPublicIP = false }
        let epoch = connectionEpoch
        let address = await prober.publicIP()
        // Drop a stale answer if the session changed or the setting was turned off meanwhile.
        guard epoch == connectionEpoch, settings.publicIPEnabled else { return }
        snapshot.connectivity.publicIP = address
        recompute(completedScan: nil)
    }

    /// The user's "Scan now": runs a full scan at once, even when not connected, then re-evaluates findings.
    /// It never overlaps a scan in flight; it asks for one more scan after it instead. A failed scan keeps the
    /// previous results.
    public func scanNow() async {
        guard !scheduler.isScanning else {
            _ = scheduler.request(now: now())
            return
        }
        await performScan()
    }

    private func performScan() async {
        scheduler.begin()
        isScanning = true
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
        isScanning = false
        if scheduler.finish(now: now()) { armScan() }
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
            resetConnectivity()
            probesStale = true
        }

        var connection: ConnectionState?
        if let link, let name, let address = link.bssid {
            connection = ConnectionState(ssid: name, bssid: address, rssi: link.rssi,
                                         gatewayMAC: snapshot.connectivity.gatewayMAC,
                                         dnsServers: snapshot.connectivity.dnsServers,
                                         dnsAnswers: snapshot.connectivity.dnsAnswers)
        }
        if let completedScan { siblingFindings = detector.findings(in: completedScan) }
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

    func task(_ key: String) -> Task<Void, Never>? { tasks[key] }

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
