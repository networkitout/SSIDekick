import Foundation
import SwiftUI
import WiFiCore
import WiFiSystem

@main
struct WiFiUtilApp: App {
    private let engine: Engine
    private let vendors: VendorLookup

    init() {
        let engine: Engine
        let vendors: VendorLookup
        if let scenario = demoScenario(arguments: CommandLine.arguments) {
            // Demo mode touches no real source: no CoreWLAN, no Location, no network.
            let demo = demoSources(scenario)
            vendors = demo.vendors
            engine = Engine(wifi: demo.wifi, config: demo.config, neighbors: demo.neighbors, prober: demo.prober,
                            location: demo.location, vendors: vendors, settings: EngineSettings())
        } else {
            // App.init runs on the main thread; both sources must be created there.
            let location = LocationAuthorizer()
            let wifi = CoreWLANSource()
            vendors = Self.bundledVendors()
            engine = Engine(wifi: wifi, config: SystemNetworkConfig(interfaceName: wifi.interfaceName ?? "en0"),
                            neighbors: ARPNeighborTable(), prober: SystemProber(), location: location,
                            vendors: vendors, settings: EngineSettings())
        }
        self.engine = engine
        self.vendors = vendors
        engine.start()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(engine: engine, vendors: vendors)
        } label: {
            StatusIcon(snapshot: engine.snapshot)
        }
        .menuBarExtraStyle(.window)

        Window("Nearby networks", id: scanWindowID) {
            ScanWindowView(engine: engine, vendors: vendors)
        }
        .defaultSize(width: 820, height: 520)
    }

    /// The vendor table copied into Contents/Resources by scripts/build-app.sh; empty if missing or unreadable.
    private static func bundledVendors() -> VendorTable {
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return VendorTable(tsv: text)
    }
}
