import AppKit
import SwiftUI
import WiFiCore

/// The menu bar glyph; see `statusGlyph(for:)` for which symbol and colour apply.
struct StatusIcon: View {
    let snapshot: Snapshot

    var body: some View {
        let glyph = statusGlyph(for: snapshot)
        image(glyph).accessibilityLabel(label(glyph))
    }

    /// Menu bar labels are drawn as templates, which drops SwiftUI colours, so a tinted glyph is a
    /// non-template NSImage with the colour baked in.
    private func image(_ glyph: StatusGlyph) -> Image {
        let color: NSColor
        switch glyph.tint {
        case .normal: return Image(systemName: glyph.symbol)
        case .orange: color = .systemOrange
        case .red: color = .systemRed
        }
        guard let base = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil),
              let tinted = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        else { return Image(systemName: glyph.symbol) }
        tinted.isTemplate = false
        return Image(nsImage: tinted)
    }

    private func label(_ glyph: StatusGlyph) -> String {
        switch glyph.tint {
        case .red: return "WiFiUtil: suspect twin on this network"
        case .orange: return "WiFiUtil: worth a look"
        case .normal:
            switch glyph.symbol {
            case "wifi.slash": return "WiFiUtil: not connected"
            case "wifi.exclamationmark": return "WiFiUtil: no internet"
            default: return "WiFiUtil"
            }
        }
    }
}
