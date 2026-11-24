import AppKit
import SwiftUI
import WiFiCore
import WiFiSystem

/// The menu bar glyph; see `statusGlyph(for:)` for which symbol and colour apply. It reads the Engine's snapshot
/// in its own body, so the glyph redraws with every change without re-evaluating the app's scenes.
struct StatusIcon: View {
    let engine: Engine
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // Hands SwiftUI's Settings opener to the right-click menu. Done in body, which always runs, because
        // onAppear isn't known to fire for a menu bar label; the assignment is cheap.
        let _ = (StatusItemContextMenu.shared.openSettings = openSettings)
        let snapshot = engine.snapshot
        image(statusGlyph(for: snapshot)).accessibilityLabel(statusAccessibilityLabel(for: snapshot))
    }

    /// Menu bar labels are drawn as templates, which drops SwiftUI colours, so a tinted glyph is a
    /// non-template NSImage with the colour baked in.
    private func image(_ glyph: StatusGlyph) -> Image {
        let color: NSColor
        switch glyph.tint {
        case .normal: return Image(systemName: glyph.symbol)
        case .dimmed: color = .secondaryLabelColor
        case .orange: color = .systemOrange
        case .red: color = .systemRed
        }
        guard let base = NSImage(systemSymbolName: glyph.symbol, accessibilityDescription: nil),
              let tinted = base.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))
        else { return Image(systemName: glyph.symbol) }
        tinted.isTemplate = false
        return Image(nsImage: tinted)
    }
}
