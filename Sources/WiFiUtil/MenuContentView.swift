import AppKit
import SwiftUI
import WiFiCore
import WiFiSystem

/// The menu bar popover: link quality, connectivity probes and the actions.
struct MenuContentView: View {
    let engine: Engine
    let vendors: VendorLookup

    private static let locationSettings =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!

    var body: some View {
        let snapshot = engine.snapshot
        VStack(alignment: .leading, spacing: 6) {
            linkBlock(snapshot)
            Divider()
            connectivityBlock(snapshot.connectivity)
            Divider()
            actions
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(12)
        .frame(width: 340, alignment: .leading)
        .onAppear { engine.menuOpen = true }
        .onDisappear { engine.menuOpen = false }
    }

    // MARK: Link

    @ViewBuilder
    private func linkBlock(_ snapshot: Snapshot) -> some View {
        if snapshot.state == .off {
            Text("Wi-Fi is off")
        } else if snapshot.state == .notConnected || snapshot.link == nil {
            Text("Not connected")
        } else if let link = snapshot.link {
            if snapshot.locationAuthorized {
                HStack(alignment: .firstTextBaseline) {
                    Text(link.ssid ?? "Unnamed network").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if let warning = twinWarning(for: snapshot) {
                        Text(warning).foregroundStyle(snapshot.connectedVerdict == .suspect ? .red : .orange)
                    }
                }
            } else {
                locationHint
            }
            Text("Signal \(link.rssi) dBm · Noise \(link.noise) · SNR \(link.snr)")
            Text(channelLine(link))
            if snapshot.locationAuthorized {
                HStack {
                    Text("Security: \(securityName(link.security))")
                    Spacer()
                    Text("AP: \(accessPointText(link.bssid))")
                }
            } else {
                Text("Security: \(securityName(link.security))")
            }
        }
    }

    private var locationHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Network names are hidden until Location Services is allowed")
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Location Services settings") { NSWorkspace.shared.open(Self.locationSettings) }
        }
    }

    private func channelLine(_ link: LinkSnapshot) -> String {
        var parts = ["Ch \(link.channel.number) (\(bandName(link.channel.band)), \(link.channel.widthMHz) MHz)"]
        if let generation = link.generation { parts.append("Wi-Fi \(generation.rawValue)") }
        parts.append("\(Int(link.txRateMbps.rounded())) Mbps")
        return parts.joined(separator: " · ")
    }

    private func accessPointText(_ address: MACAddress?) -> String {
        guard let address else { return "–" }
        guard let vendor = vendors.vendor(for: address) else { return address.description }
        return "\(address) (\(vendor))"
    }

    // MARK: Connectivity

    @ViewBuilder
    private func connectivityBlock(_ net: ConnectivitySnapshot) -> some View {
        row("Gateway \(net.gatewayIP ?? "–")",
            "\(millis(net.gatewayLatencyMs))   \(net.gatewayLossPercent.map { "\($0)% loss" } ?? "– loss")")
        row("DNS \(net.dnsServers.first ?? "–")", millis(net.dnsLatencyMs))
        row("Internet", internetText(net))
        Text(addressLine(net))
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
        }
    }

    private func internetText(_ net: ConnectivitySnapshot) -> String {
        switch net.internet {
        case .unknown: "checking…"
        case .online: "✓  \(millis(net.internetLatencyMs)) · captive portal: no"
        case .captivePortal: "captive portal: yes"
        case .offline: "✗  offline"
        }
    }

    private func addressLine(_ net: ConnectivitySnapshot) -> String {
        var line = "IP \(net.ipv4.first ?? net.ipv6.first ?? "–")"
        if let publicIP = net.publicIP { line += " · Public \(publicIP)" }
        return line
    }

    private func millis(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "– ms" }

    // MARK: Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Enabled by Task 11 (scan window).
            menuButton("Nearby networks…") {}.disabled(true)
            HStack {
                menuButton("Scan now") { Task { await engine.scanNow() } }
                menuButton("Copy report") { copyReport() }
            }
            HStack {
                // Enabled by Task 12 (settings).
                menuButton("Settings…") {}.disabled(true)
                menuButton("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func menuButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
    }

    private func copyReport() {
        let report = formatReport(engine.snapshot, vendors: vendors, now: Date())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    // MARK: Names

    private func bandName(_ band: Band) -> String {
        switch band {
        case .ghz2_4: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        }
    }

    private func securityName(_ mode: SecurityMode?) -> String {
        switch mode {
        case .open: "Open"
        case .wep: "WEP"
        case .wpa: "WPA"
        case .wpa2: "WPA2"
        case .wpa3: "WPA3"
        case nil: "–"
        }
    }
}
