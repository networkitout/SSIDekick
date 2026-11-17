import AppKit
import SwiftUI
import WiFiCore
import WiFiSystem

let scanWindowID = "scan"
let locationHintText = "Network names are hidden until Location Services is allowed"

func bandName(_ band: Band) -> String {
    switch band {
    case .ghz2_4: "2.4 GHz"
    case .ghz5: "5 GHz"
    case .ghz6: "6 GHz"
    }
}

func securityName(_ mode: SecurityMode?) -> String {
    switch mode {
    case .open: "Open"
    case .wep: "WEP"
    case .wpa: "WPA"
    case .wpa2: "WPA2"
    case .wpa3: "WPA3"
    case nil: "–"
    }
}

/// The "Nearby networks" window: every access point in range grouped by network name, and the channel view.
struct ScanWindowView: View {
    let engine: Engine
    let vendors: VendorLookup
    let windowState: ScanWindowState

    private enum Tab: Hashable { case networks, channels }
    @State private var tab: Tab = .networks

    var body: some View {
        let snapshot = engine.snapshot
        VStack(spacing: 0) {
            header(snapshot)
            Divider()
            TabView(selection: $tab) {
                NetworksTab(snapshot: snapshot, vendors: vendors, revealRequests: windowState.revealRequests)
                    .tabItem { Text("Networks") }
                    .tag(Tab.networks)
                ChannelCrowdingView(snapshot: snapshot)
                    .tabItem { Text("Channels") }
                    .tag(Tab.channels)
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private func header(_ snapshot: Snapshot) -> some View {
        HStack(spacing: 12) {
            // Re-evaluated every second so "Scanned 12 s ago" keeps counting.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(scanAgeText(scanTime: snapshot.scanTime, now: context.date))
            }
            if let error = snapshot.scanError {
                Text(error).foregroundStyle(.red).lineLimit(1)
            }
            if vendors.isEmpty {
                Text(vendorTableMissingText).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Scan now") { Task { await engine.scanNow() } }
                .disabled(engine.isScanning)
        }
        .padding(10)
    }
}

// MARK: - Networks tab

private struct NetworksTab: View {
    let snapshot: Snapshot
    let vendors: VendorLookup
    /// Changes when the menu asks to show the connected network.
    let revealRequests: Int
    /// Groups the user has toggled; absent means the default (the connected group is open).
    @State private var toggled: [String: Bool] = [:]
    /// Devices the user has toggled, by device id; absent means the default (open only for the connected radio's device).
    @State private var toggledDevices: [String: Bool] = [:]

    var body: some View {
        if !snapshot.locationAuthorized {
            VStack(spacing: 8) {
                Text(locationHintText)
                Button("Open Location Services settings") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
                }
                Text("The Channels tab still works without names.").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let groups = groupScan(snapshot.scan, findings: snapshot.findings, connectedSSID: snapshot.link?.ssid)
            if groups.isEmpty {
                Text("No networks found yet. Use Scan now.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        columnTitles
                        ForEach(groups) { group in
                            groupView(group)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                // Runs when the tab appears and on every request from the menu's warning line.
                .task(id: revealRequests) {
                    if let ssid = snapshot.link?.ssid { toggled[ssid] = true }
                }
            }
        }
    }

    private func isExpanded(_ group: NetworkGroup) -> Bool { toggled[group.id] ?? group.isConnected }

    private var columnTitles: some View {
        HStack(spacing: 8) {
            Text("Address").frame(width: Col.address, alignment: .leading)
            Text("Vendor").frame(width: Col.vendor, alignment: .leading)
            Text("Channel").frame(width: Col.channel, alignment: .leading)
            Text("Band").frame(width: Col.band, alignment: .leading)
            Text("Signal").frame(width: Col.signal, alignment: .trailing)
            Text("Security").frame(width: Col.security, alignment: .leading)
            Text("Wi-Fi").frame(width: Col.generation, alignment: .leading)
            Text("Findings").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.vertical, 6)
    }

    private func groupView(_ group: NetworkGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggled[group.id] = !isExpanded(group)
            } label: {
                groupHeader(group)
            }
            .buttonStyle(.plain)
            if isExpanded(group) {
                if group.isConnected, let ssid = group.ssid {
                    // Every finding without a row of its own, so the menu bar icon is always explained here.
                    let unlisted = connectedHeaderFindings(ssid: ssid, scan: snapshot.scan, findings: snapshot.findings)
                    ForEach(Array(unlisted.enumerated()), id: \.offset) {
                        Text(headerFindingText($0.element))
                            .font(.caption).foregroundStyle(tint(for: group.verdict) ?? .secondary)
                            .padding(.leading, 22).padding(.vertical, 2)
                    }
                }
                let devices = groupDevices(group.accessPoints, findings: snapshot.findings)
                ForEach(devices) { device in
                    if device.isSingleRadio {
                        row(device.accessPoints[0])
                    } else {
                        deviceView(device, in: group)
                    }
                }
            }
            Divider()
        }
    }

    private struct RadioRow: Identifiable {
        let offset: Int
        let accessPoint: AccessPoint
        var id: String { accessPoint.bssid?.description ?? "none-\(offset)" }
    }

    private func isExpanded(_ device: DeviceGroup, in group: NetworkGroup) -> Bool {
        if let toggled = toggledDevices[device.id] { return toggled }
        guard group.isConnected, let connected = snapshot.link?.bssid else { return false }
        return device.accessPoints.contains { $0.bssid == connected }
    }

    private func deviceView(_ device: DeviceGroup, in group: NetworkGroup) -> some View {
        let expanded = isExpanded(device, in: group)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                toggledDevices[device.id] = !expanded
            } label: {
                deviceHeader(device, expanded: expanded)
            }
            .buttonStyle(.plain)
            .help("Probably one device: same maker prefix and neighbouring addresses")
            if expanded {
                // Addresses are unique within a device; only a missing address falls back to its position.
                ForEach(device.accessPoints.enumerated().map { RadioRow(offset: $0.offset, accessPoint: $0.element) }) {
                    row($0.accessPoint, indent: 44)
                }
            }
        }
    }

    private func deviceHeader(_ device: DeviceGroup, expanded: Bool) -> some View {
        let vendor = device.accessPoints.compactMap(\.bssid).min { $0.bytes.lexicographicallyPrecedes($1.bytes) }
            .flatMap { vendors.vendor(for: $0) } ?? "–"
        return HStack(spacing: 8) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .frame(width: 12).foregroundStyle(.secondary)
            Image(systemName: "wifi.router").foregroundStyle(.secondary)
            Text(device.addressPattern).frame(width: Col.address - 34, alignment: .leading)
            Text(vendor).lineLimit(1).frame(width: Col.vendor, alignment: .leading)
            Text(device.bands.map(bandName).joined(separator: " · "))
                .frame(width: Col.channel + Col.band, alignment: .leading)
            Text("\(device.accessPoints.count) radios").foregroundStyle(.secondary)
            Spacer()
            Text("\(device.strongestRSSI) dBm")
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.vertical, 4).padding(.leading, 22)
        .contentShape(Rectangle())
    }

    private func groupHeader(_ group: NetworkGroup) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isExpanded(group) ? "chevron.down" : "chevron.right")
                .frame(width: 12).foregroundStyle(.secondary)
            Text(group.ssid ?? "Hidden network").font(.system(size: 13, weight: .semibold))
            if group.isConnected { Text("connected").font(.caption).foregroundStyle(.secondary) }
            Text(group.ssid == nil
                 ? "1 access point"
                 : devicesSummary(groupDevices(group.accessPoints, findings: snapshot.findings)))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch group.verdict {
            case .suspect: Text("suspect").foregroundStyle(.red)
            case .worthALook: Text("worth a look").foregroundStyle(.orange)
            case .note, .clear: EmptyView()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func row(_ accessPoint: AccessPoint, indent: CGFloat = 22) -> some View {
        let mine = findings(for: accessPoint, in: snapshot.findings)
        let rowVerdict = verdict(for: mine)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(accessPoint.bssid?.description ?? "–").frame(width: Col.address, alignment: .leading)
                Text(accessPoint.bssid.flatMap { vendors.vendor(for: $0) } ?? "–")
                    .lineLimit(1).frame(width: Col.vendor, alignment: .leading)
                Text("\(accessPoint.channel.number) · \(accessPoint.channel.widthMHz) MHz")
                    .frame(width: Col.channel, alignment: .leading)
                Text(bandName(accessPoint.channel.band)).frame(width: Col.band, alignment: .leading)
                Text("\(accessPoint.rssi) dBm").frame(width: Col.signal, alignment: .trailing)
                Text(accessPoint.security.isEmpty ? "–" : securityName(accessPoint.weakestSecurity))
                    .frame(width: Col.security, alignment: .leading)
                Text(accessPoint.generation.map { "Wi-Fi \($0.rawValue)" } ?? "–")
                    .frame(width: Col.generation, alignment: .leading)
                Text(mine.isEmpty ? "–" : "\(mine.count)").frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(mine.enumerated()), id: \.offset) {
                Text($0.element.reason).font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.vertical, 4).padding(.leading, indent)
        .background(tint(for: rowVerdict)?.opacity(0.15) ?? .clear)
    }

    private func tint(for verdict: Verdict) -> Color? {
        switch verdict {
        case .suspect: .red
        case .worthALook: .orange
        case .note, .clear: nil
        }
    }

    private enum Col {
        static let address: CGFloat = 130
        static let vendor: CGFloat = 130
        static let channel: CGFloat = 100
        static let band: CGFloat = 60
        static let signal: CGFloat = 70
        static let security: CGFloat = 70
        static let generation: CGFloat = 60
    }
}
