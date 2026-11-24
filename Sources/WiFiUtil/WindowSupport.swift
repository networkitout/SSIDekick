import AppKit
import Observation
import SwiftUI

/// Shared between the menu and the scan window: the menu's warning line asks the window to re-expand the
/// connected network's group, even when the user collapsed it.
@MainActor @Observable
final class ScanWindowState {
    /// Bumped on every request; the window reacts to each change.
    private(set) var revealRequests = 0

    func revealConnected() { revealRequests += 1 }
}

/// Reports whether the window hosting this view is open: true when it becomes key (or is visible when the view
/// arrives), false when it resigns key or closes. Used to drive `Engine.menuOpen` from the popover's own window.
/// `onWindow` is handed the hosting window each time the view moves into one.
struct HostWindowObserver: NSViewRepresentable {
    let onChange: (Bool) -> Void
    var onWindow: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> ObserverView { ObserverView(onChange: onChange, onWindow: onWindow) }

    func updateNSView(_ view: ObserverView, context: Context) {
        view.onChange = onChange
        view.onWindow = onWindow
    }

    final class ObserverView: NSView {
        var onChange: (Bool) -> Void
        var onWindow: (NSWindow) -> Void
        private var tokens: [NSObjectProtocol] = []

        init(onChange: @escaping (Bool) -> Void, onWindow: @escaping (NSWindow) -> Void) {
            self.onChange = onChange
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        deinit {
            for token in tokens { NotificationCenter.default.removeObserver(token) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for token in tokens { NotificationCenter.default.removeObserver(token) }
            tokens = []
            guard let window else { return }
            onWindow(window)
            let center = NotificationCenter.default
            let report: (Bool) -> Void = { [weak self] open in self?.onChange(open) }
            tokens = [
                center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { _ in
                    report(true)
                },
                center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { _ in
                    report(false)
                },
                center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    report(false)
                },
            ]
            // Reported after the current view update, never during it.
            let visible = window.isVisible || window.isKeyWindow
            DispatchQueue.main.async { report(visible) }
        }
    }
}

/// Keeps the app running when its last window closes: it lives in the menu bar.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        StatusItemContextMenu.shared.install()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
