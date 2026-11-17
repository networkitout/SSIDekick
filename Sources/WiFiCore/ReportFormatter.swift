import Foundation

private let hiddenByLocation = "hidden (Location Services off)"

private func bandName(_ band: Band) -> String {
    switch band {
    case .ghz2_4: "2.4 GHz"
    case .ghz5: "5 GHz"
    case .ghz6: "6 GHz"
    }
}

private func channelText(_ channel: Channel) -> String {
    "Ch \(channel.number) (\(bandName(channel.band)), \(channel.widthMHz) MHz)"
}

private func generationText(_ generation: WiFiGeneration?) -> String {
    generation.map { "Wi-Fi \($0.rawValue)" } ?? "n/a"
}

private func securityText(_ mode: SecurityMode?) -> String {
    switch mode {
    case .open: "open"
    case .wep: "WEP"
    case .wpa: "WPA"
    case .wpa2: "WPA2"
    case .wpa3: "WPA3"
    case nil: "n/a"
    }
}

private func securityText(_ modes: Set<SecurityMode>) -> String {
    modes.isEmpty ? "open" : modes.sorted().map { securityText($0) }.joined(separator: "/")
}

private func millis(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) ms" } ?? "n/a" }
private func list(_ values: [String]) -> String { values.isEmpty ? "n/a" : values.joined(separator: ", ") }

private func internetText(_ status: InternetStatus) -> String {
    switch status {
    case .unknown: "n/a"
    case .online: "online"
    case .captivePortal: "captive portal"
    case .offline: "offline"
    }
}

/// Plain-text report of facts. Never judges a network as good, only lists what was seen.
public func formatReport(_ snapshot: Snapshot, vendors: VendorLookup, now: Date) -> String {
    let visible = snapshot.locationAuthorized
    var lines: [String] = []

    lines.append("WiFiUtil report \(now.formatted(.iso8601))")

    lines.append("")
    lines.append("Link")
    switch snapshot.state {
    case .off: lines.append("Wi-Fi is off")
    case .notConnected: lines.append("Not connected")
    case .connected: lines.append("Connected")
    }
    if let error = snapshot.eventMonitoringError {
        lines.append("Wi-Fi event monitoring could not start: \(error)")
    }
    if let link = snapshot.link {
        lines.append("Network: \(visible ? (link.ssid ?? "n/a") : hiddenByLocation)")
        lines.append("Access point: \(visible ? (link.bssid?.description ?? "n/a") : hiddenByLocation)")
        lines.append("Signal \(link.rssi) dBm, noise \(link.noise) dBm, SNR \(link.snr) dB")
        lines.append("\(channelText(link.channel)), \(generationText(link.generation)), \(securityText(link.security))")
        lines.append("Tx rate \(Int(link.txRateMbps.rounded())) Mbps, country \(link.countryCode ?? "n/a")")
    } else {
        lines.append("Network: n/a")
        lines.append("Access point: n/a")
    }

    let net = snapshot.connectivity
    lines.append("")
    lines.append("Connectivity")
    lines.append("Gateway: \(net.gatewayIP ?? "n/a"), address \(visible ? (net.gatewayMAC?.description ?? "n/a") : hiddenByLocation)")
    if net.gatewayBlocked {
        lines.append("Gateway latency: blocked")
    } else {
        lines.append("Gateway latency: \(millis(net.gatewayLatencyMs)), loss \(net.gatewayLossPercent.map { "\($0)%" } ?? "n/a")")
    }
    lines.append("DNS: \(list(net.dnsServers)), latency \(net.dnsBlocked ? "blocked" : millis(net.dnsLatencyMs))")
    lines.append("Internet: \(internetText(net.internet)), latency \(millis(net.internetLatencyMs))")
    lines.append("IPv4: \(list(net.ipv4))")
    lines.append("IPv6: \(list(net.ipv6))")
    lines.append("Public IP: \(net.publicIP ?? "n/a")")

    lines.append("")
    lines.append("Findings")
    if snapshot.findings.isEmpty {
        lines.append("No findings.")
    } else if visible {
        for finding in snapshot.findings {
            lines.append("- \(finding.ssid) \(finding.bssid?.description ?? "connection"): \(finding.reason)")
        }
    } else {
        lines.append("\(snapshot.findings.count) finding(s) \(hiddenByLocation)")
    }

    lines.append("")
    lines.append("Nearby networks")
    if let error = snapshot.scanError { lines.append("Scan error: \(error)") }
    if let time = snapshot.scanTime { lines.append("Scanned \(time.formatted(.iso8601))") }
    if !visible {
        lines.append("\(snapshot.scan.count) access point(s) seen; names and addresses \(hiddenByLocation)")
    } else if snapshot.scan.isEmpty {
        lines.append("n/a")
    } else {
        let groups = Dictionary(grouping: snapshot.scan) { $0.ssid ?? "(hidden)" }
        for name in groups.keys.sorted() {
            lines.append(name)
            for point in groups[name]! {
                let address = point.bssid?.description ?? "n/a"
                let vendor = point.bssid.flatMap { vendors.vendor(for: $0) } ?? "n/a"
                lines.append("  \(address), vendor \(vendor), \(channelText(point.channel)), "
                             + "Signal \(point.rssi) dBm, \(securityText(point.security))")
            }
        }
    }

    return lines.joined(separator: "\n") + "\n"
}
