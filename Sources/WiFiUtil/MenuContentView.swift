import AppKit
import SwiftUI
import WiFiCore
import WiFiSystem

/// The menu bar popover: link quality, connectivity probes and the actions.
struct MenuContentView: View {
    let engine: Engine
    let vendors: VendorLookup
    let windowState: ScanWindowState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettingsWindow

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
        // Belt-and-braces pending the visual pass: onAppear/onDisappear of a window-style MenuBarExtra are not
        // verified, so the popover's own window also drives menuOpen (key or visible: open; resigned or closed: shut).
        .background(HostWindowObserver { engine.menuOpen = $0 })
    }

    // MARK: Link

    @ViewBuilder
    private func linkBlock(_ snapshot: Snapshot) -> some View {
        if snapshot.state == .off {
            Text("Wi-Fi is off")
        } else if snapshot.state == .notConnected || snapshot.link == nil {
            Text("Not connected")
        } else if let link = snapshot.link {
            warningBanner(warningLines(for: snapshot))
            if snapshot.locationAuthorized {
                HStack(alignment: .firstTextBaseline) {
                    Text(link.ssid ?? "Unnamed network").font(.system(size: 13, weight: .semibold))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer()
                    networkChip(link)
                }
            } else {
                locationHint
            }
            sectionLabel("Link", symbol: "antenna.radiowaves.left.and.right")
            signalRow(link)
            snrRow(link)
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

    /// One tinted banner for all warning lines; red if any is suspect, else orange. Tapping reveals the network.
    @ViewBuilder
    private func warningBanner(_ warnings: [WarningLine]) -> some View {
        if !warnings.isEmpty {
            let tint: Color = warnings.contains { $0.verdict == .suspect } ? .red : .orange
            // Opens the scan window with the connected group expanded, even if it was collapsed.
            Button(action: revealConnectedNetwork) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(warnings, id: \.text) { Text($0.text) }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// "Wi-Fi N · band" when the generation is known, the band alone otherwise.
    private func networkChip(_ link: LinkSnapshot) -> some View {
        let band = bandName(link.channel.band)
        let text = link.generation.map { "Wi-Fi \($0.rawValue) · \(band)" } ?? band
        return Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.green)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Color.green.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func signalRow(_ link: LinkSnapshot) -> some View {
        let level = signalLevel(rssi: link.rssi)
        let color = levelColor(level)
        let filled = signalBars(rssi: link.rssi)
        let heights: [CGFloat] = [5, 8, 11, 14]
        let reading = level == .unknown ? "–" : "\(link.rssi) dBm"
        return HStack {
            Text("Signal \(reading)")
            Spacer()
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < filled ? color : Color.secondary.opacity(0.3))
                        .frame(width: 4, height: heights[index])
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(reading), \(levelWord(level))")
    }

    private func snrRow(_ link: LinkSnapshot) -> some View {
        let level = snrLevel(rssi: link.rssi, noise: link.noise)
        // A reading of 0 or above is a failed measurement; show "–" for it (and for the SNR it spoils).
        let noise = link.noise >= 0 ? "–" : "\(link.noise)"
        let snr = level == .unknown ? "–" : "\(link.snr)"
        return HStack {
            Text("Noise \(noise) · SNR \(snr)")
            Spacer()
            if level != .unknown {
                Text(levelWord(level)).foregroundStyle(levelColor(level))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Noise \(noise), SNR \(snr), \(levelWord(level))")
    }

    private func levelColor(_ level: QualityLevel) -> Color {
        switch level {
        case .good: .green
        case .fair: .orange
        case .poor: .red
        case .unknown: .secondary
        }
    }

    private func levelWord(_ level: QualityLevel) -> String {
        switch level {
        case .good: "good"
        case .fair: "fair"
        case .poor: "poor"
        case .unknown: "unknown"
        }
    }

    private var locationHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(locationHintText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Location Services settings") { NSWorkspace.shared.open(Self.locationSettings) }
        }
    }

    private func channelLine(_ link: LinkSnapshot) -> String {
        // The Wi-Fi generation is in the chip beside the network name.
        "Ch \(link.channel.number) (\(bandName(link.channel.band)), \(link.channel.widthMHz) MHz)"
            + " · \(Int(link.txRateMbps.rounded())) Mbps"
    }

    private func accessPointText(_ address: MACAddress?) -> String {
        guard let address else { return "–" }
        guard let vendor = vendors.vendor(for: address) else { return address.description }
        return "\(address) (\(vendor))"
    }

    // MARK: Connectivity

    @ViewBuilder
    private func connectivityBlock(_ net: ConnectivitySnapshot) -> some View {
        sectionLabel("Connectivity", symbol: "globe")
        // "blocked": the probe could not be sent (for example Local Network access was refused), which is not loss.
        row("Gateway \(net.gatewayIP ?? "–")",
            net.gatewayBlocked
                ? "blocked"
                : "\(millis(net.gatewayLatencyMs))   \(net.gatewayLossPercent.map { "\($0)% loss" } ?? "– loss")",
            level: gatewayLevel(net))
        row("DNS \(net.dnsServers.first ?? "–")", net.dnsBlocked ? "blocked" : millis(net.dnsLatencyMs),
            level: dnsLevel(net))
        row("Internet", internetText(net), level: internetLevel(net.internet), tintValue: true)
        Text(addressLine(net))
    }

    private func row(_ title: String, _ value: String, level: QualityLevel, tintValue: Bool = false) -> some View {
        HStack(spacing: 6) {
            Circle().fill(levelColor(level)).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(tintValue ? levelColor(level) : .primary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(levelWord(level))")
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
            menuButton("Nearby networks…", action: openScanWindow)
            HStack {
                menuButton("Scan now") { Task { await engine.scanNow() } }
                menuButton("Copy report") { copyReport() }
            }
            HStack {
                menuButton("Settings…", action: openSettings)
                menuButton("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
    }

    private func revealConnectedNetwork() {
        windowState.revealConnected()
        openScanWindow()
    }

    private func openScanWindow() {
        // The popover is the key window until the scan window opens; hide it by hand because SwiftUI may not.
        // Not checked visually: if SwiftUI already dismisses the popover, orderOut on it is harmless.
        let popover = NSApp.keyWindow
        openWindow(id: scanWindowID)
        NSApp.activate()
        popover?.orderOut(nil)
    }

    private func openSettings() {
        let popover = NSApp.keyWindow
        openSettingsWindow()
        NSApp.activate()
        popover?.orderOut(nil)
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
}
