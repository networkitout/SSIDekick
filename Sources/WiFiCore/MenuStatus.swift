import Foundation

/// Colour of the menu bar glyph. `normal` follows the menu bar's own colour; `dimmed` is the same, muted.
public enum StatusTint: Sendable, Equatable { case normal, dimmed, orange, red }

/// What the menu bar icon shows: an SF Symbol name and a tint.
public struct StatusGlyph: Sendable, Equatable {
    public var symbol: String
    public var tint: StatusTint

    public init(symbol: String, tint: StatusTint) {
        self.symbol = symbol
        self.tint = tint
    }
}

private let antennaSymbol = "antenna.radiowaves.left.and.right"

/// Whether the Mac is on a Wi-Fi network; the antenna is slashed otherwise.
private func isOnNetwork(_ snapshot: Snapshot) -> Bool {
    snapshot.state == .connected && snapshot.link != nil
}

/// Slashed when Wi-Fi is off or not connected; otherwise coloured by the connected network's twin verdict,
/// and only when that is clear (or a note) does a missing internet show as a circled, dimmed antenna.
public func statusGlyph(for snapshot: Snapshot) -> StatusGlyph {
    guard isOnNetwork(snapshot) else {
        return StatusGlyph(symbol: antennaSymbol + ".slash", tint: .normal)
    }
    switch snapshot.connectedVerdict {
    case .suspect: return StatusGlyph(symbol: antennaSymbol, tint: .red)
    case .worthALook: return StatusGlyph(symbol: antennaSymbol, tint: .orange)
    case .clear, .note: break
    }
    if snapshot.connectivity.internet == .offline {
        return StatusGlyph(symbol: antennaSymbol + ".circle", tint: .dimmed)
    }
    return StatusGlyph(symbol: antennaSymbol, tint: .normal)
}

/// One warning line in the menu, with the verdict that colours it.
public struct WarningLine: Sendable, Equatable {
    public var text: String
    public var verdict: Verdict

    public init(text: String, verdict: Verdict) {
        self.text = text
        self.verdict = verdict
    }
}

/// The twin line: access points (findings with an address) of the connected network at their worst verdict, when
/// that is "worth a look" or higher. Connection-level findings are never counted as twins.
public func twinWarning(for snapshot: Snapshot) -> WarningLine? {
    guard snapshot.connectedVerdict >= .worthALook, let ssid = snapshot.link?.ssid else { return nil }
    let mine = snapshot.findings.filter { $0.ssid == ssid && $0.bssid != nil }
    let verdicts = Set(mine.map(\.bssid)).map { address in verdict(for: mine.filter { $0.bssid == address }) }
    guard let worst = verdicts.max(), worst >= .worthALook else { return nil }
    let count = verdicts.filter { $0 == worst }.count
    let text = worst == .suspect ? "\(count) suspect \(count == 1 ? "twin" : "twins")" : "\(count) worth a look"
    return WarningLine(text: text, verdict: worst)
}

/// The connection line: "Gateway changed", "DNS servers changed" or "Gateway and DNS changed".
public func connectionWarning(for snapshot: Snapshot) -> WarningLine? {
    guard snapshot.connectedVerdict >= .worthALook, let ssid = snapshot.link?.ssid else { return nil }
    let mine = connectionFindings(ssid: ssid, in: snapshot.findings)
    let bucket = verdict(for: mine)
    guard bucket >= .worthALook else { return nil }
    let signals = Set(mine.map(\.signal))
    let text: String
    switch (signals.contains(.gatewayChanged), signals.contains(.dnsChanged)) {
    case (true, true): text = "Gateway and DNS changed"
    case (true, false): text = "Gateway changed"
    case (false, true): text = "DNS servers changed"
    case (false, false): return nil
    }
    return WarningLine(text: text, verdict: bucket)
}

/// The DNS answers line, when a tampered answer was found on the connected network.
public func dnsAnswersWarning(for snapshot: Snapshot) -> WarningLine? {
    guard let ssid = snapshot.link?.ssid,
          connectionFindings(ssid: ssid, in: snapshot.findings).contains(where: { $0.signal == .dnsTampered })
    else { return nil }
    return WarningLine(text: "DNS answers tampered", verdict: .suspect)
}

/// The menu's warning lines: the twin line, the connection line, then the DNS answers line; empty below "worth a look".
public func warningLines(for snapshot: Snapshot) -> [WarningLine] {
    [twinWarning(for: snapshot), connectionWarning(for: snapshot), dnsAnswersWarning(for: snapshot)].compactMap { $0 }
}

/// The menu bar icon's accessibility label, following the same wording as the glyph and the warning lines.
/// It reads the snapshot, never the symbol name.
public func statusAccessibilityLabel(for snapshot: Snapshot) -> String {
    guard isOnNetwork(snapshot) else { return "SSIDekick: not connected" }
    switch snapshot.connectedVerdict {
    case .suspect, .worthALook:
        let lines = warningLines(for: snapshot).map(\.text)
        if !lines.isEmpty { return "SSIDekick: " + lines.joined(separator: "; ") }
        return snapshot.connectedVerdict == .suspect ? "SSIDekick: suspect" : "SSIDekick: worth a look"
    case .clear, .note:
        return snapshot.connectivity.internet == .offline ? "SSIDekick: no internet" : "SSIDekick"
    }
}
