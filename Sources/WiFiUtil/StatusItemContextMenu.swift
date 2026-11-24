import AppKit
import SwiftUI
import WiFiSystem

/// The right-click menu on the menu bar icon (Settings…, Quit). SwiftUI's `MenuBarExtra` has no right-click
/// hook, so a local event monitor watches mouse-downs on the app's status bar button and, for a right-click
/// or Control-click (`isStatusMenuClick`), shows this menu and swallows the event so the panel stays shut.
/// It relies on the button being an `NSStatusBarButton` in the event's window. If a future macOS changes
/// that, the monitor finds no button and every click opens the panel as before.
@MainActor
final class StatusItemContextMenu: NSObject {
    static let shared = StatusItemContextMenu()

    /// SwiftUI's Settings opener, captured from a view in the app's scenes (see `StatusIcon`).
    var openSettings: OpenSettingsAction?

    /// The panel's window, reported by `MenuContentView`; hidden before the menu shows so the two never overlap.
    weak var panelWindow: NSWindow?

    private var monitor: Any?

    /// Starts watching clicks; later calls do nothing, so there is only ever one monitor.
    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            // Local monitors run on the main thread.
            let shown = MainActor.assumeIsolated { StatusItemContextMenu.shared.showMenuIfStatusClick(event) }
            return shown ? nil : event
        }
    }

    /// Shows the menu and returns true when `event` is a right-click or Control-click on the status button.
    private func showMenuIfStatusClick(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard isStatusMenuClick(rightButton: event.type == .rightMouseDown, control: flags.contains(.control),
                                command: flags.contains(.command)),
              let window = event.window,
              let button = window.contentView.flatMap(Self.statusButton(in:))
        else { return false }

        // The swallowed click can't close an open panel, so hide it here, as the panel's own Settings button does.
        if let panel = panelWindow, panel.isVisible { panel.orderOut(nil) }
        button.highlight(true)
        // Screen coordinates (no view): the menu's top-left sits just under the icon, like other menu bar menus.
        makeMenu().popUp(positioning: nil, at: NSPoint(x: window.frame.minX, y: window.frame.minY - 4), in: nil)
        button.highlight(false)
        return true
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusButton(in: subview) { return button }
        }
        return nil
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit SSIDekick", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    /// Same order as the panel's Settings button (open, then activate), which brings Settings to the front in
    /// this accessory app.
    @objc private func showSettings() {
        if let openSettings {
            openSettings()
        } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        NSApp.activate()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
