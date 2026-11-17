import Foundation

/// Colour of the menu bar glyph. `normal` follows the menu bar's own colour.
public enum StatusTint: Sendable, Equatable { case normal, orange, red }

/// What the menu bar icon shows: an SF Symbol name and a tint.
public struct StatusGlyph: Sendable, Equatable {
    public var symbol: String
    public var tint: StatusTint

    public init(symbol: String, tint: StatusTint) {
        self.symbol = symbol
        self.tint = tint
    }
}

/// Slashed when Wi-Fi is off or not connected; otherwise coloured by the connected network's twin verdict,
/// and only when that is clear (or a note) does a missing internet show as an exclamation mark.
public func statusGlyph(for snapshot: Snapshot) -> StatusGlyph {
    guard snapshot.state == .connected, snapshot.link != nil else {
        return StatusGlyph(symbol: "wifi.slash", tint: .normal)
    }
    switch snapshot.connectedVerdict {
    case .suspect: return StatusGlyph(symbol: "wifi", tint: .red)
    case .worthALook: return StatusGlyph(symbol: "wifi", tint: .orange)
    case .clear, .note: break
    }
    if snapshot.connectivity.internet == .offline {
        return StatusGlyph(symbol: "wifi.exclamationmark", tint: .normal)
    }
    return StatusGlyph(symbol: "wifi", tint: .normal)
}

/// The menu's warning line, or nil when the connected network is below "worth a look".
/// N counts the connected network's access points (and the connection itself, for gateway or DNS findings)
/// whose own verdict equals the network's verdict.
public func twinWarning(for snapshot: Snapshot) -> String? {
    guard snapshot.connectedVerdict >= .worthALook, let ssid = snapshot.link?.ssid else { return nil }
    let mine = snapshot.findings.filter { $0.ssid == ssid }
    let count = Set(mine.map(\.bssid))
        .filter { address in verdict(for: mine.filter { $0.bssid == address }) == snapshot.connectedVerdict }
        .count
    guard count > 0 else { return nil }
    switch snapshot.connectedVerdict {
    case .suspect: return "⚠ \(count) suspect \(count == 1 ? "twin" : "twins")"
    default: return "⚠ \(count) worth a look"
    }
}
