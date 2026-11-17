import AppKit
import Foundation
import SwiftUI
import WiFiCore
import WiFiSystem

@main
struct WiFiUtilApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let engine: Engine
    private let vendors: VendorLookup
    private let notifier = Notifier()
    private let windowState = ScanWindowState()

    init() {
        let engine: Engine
        let vendors: VendorLookup
        // Stored settings are read before the Engine exists so the first scan interval is the stored one.
        let settings = loadEngineSettings(from: .standard)
        if let scenario = demoScenario(arguments: CommandLine.arguments) {
            // Demo mode touches no real source: no CoreWLAN, no Location, no network.
            let demo = demoSources(scenario)
            vendors = demo.vendors
            engine = Engine(wifi: demo.wifi, config: demo.config, neighbors: demo.neighbors, prober: demo.prober,
                            location: demo.location, vendors: vendors, settings: settings)
        } else {
            // App.init runs on the main thread; both sources must be created there.
            let location = LocationAuthorizer()
            let wifi = CoreWLANSource()
            vendors = Self.bundledVendors()
            let interfaceName = wifi.interfaceName ?? "en0"
            engine = Engine(wifi: wifi, config: SystemNetworkConfig(interfaceName: interfaceName),
                            neighbors: ARPNeighborTable(interfaceName: interfaceName),
                            prober: SystemProber(interfaceName: interfaceName), location: location,
                            vendors: vendors, settings: settings)
        }
        self.engine = engine
        self.vendors = vendors
        let notifier = notifier
        engine.onNewFindings = { findings in notifier.post(findings) }
        // Sleep can carry the Mac to another network under the same name; a wake always starts a new session.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { engine.noteWake() }
        }
        engine.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(engine: engine, vendors: vendors, windowState: windowState)
        } label: {
            StatusIcon(engine: engine)
        }
        .menuBarExtraStyle(.window)

        Window("Nearby networks", id: scanWindowID) {
            ScanWindowView(engine: engine, vendors: vendors, windowState: windowState)
        }
        .defaultSize(width: 820, height: 520)
        // Opens only when asked for, never at launch or from a restored session.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(engine: engine)
        }
    }

    /// The vendor table copied into Contents/Resources by scripts/build-app.sh; empty if missing or unreadable.
    private static func bundledVendors() -> VendorTable {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return VendorTable(tsv: text)
    }
}
