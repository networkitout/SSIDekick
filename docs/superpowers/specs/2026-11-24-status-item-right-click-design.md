# Right-click menu on the menu bar icon: design

Status: approved by the owner, 2026-11-24.

## Intent

The owner wants to reach Settings and quit SSIDekick by right-clicking the menu bar icon, without
opening the full panel and finding its bottom buttons. Left-click keeps opening the panel as it does today.

## Goals

- Right-click and Control-click on the icon show a native menu:
  `Settings…` (⌘,), a separator, `Quit SSIDekick` (⌘Q).
- `Settings…` opens the Settings window the same way the panel's button does (SwiftUI `openSettings`,
  then activate the app).
- Left-click is unchanged.

## Non-goals

- No other items in the menu (Nearby networks, Scan now, Copy report stay in the panel).
- No change to the panel's own Settings… and Quit buttons.

## Anti-goals

- Breaking the panel, the Nearby networks window or the Settings window.
- Right-click showing both the menu and the panel.

## Constraints

- The icon is a SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.window)`, which offers no separate
  right-click handling.
- Main thread / `@MainActor` for all AppKit work; Swift 5 language mode in the WiFiUtil target.

## Approaches

1. **Keep `MenuBarExtra`; catch right-clicks with a local event monitor (chosen).** An
   `NSEvent.addLocalMonitorForEvents` for right-mouse-down, and left-mouse-down with Control, checks
   whether the event landed on the app's `NSStatusBarButton`. If so, it pops up an `NSMenu` under the
   button and swallows the event. Small (one new file plus a line to install it), and keeps all
   existing behaviour. Trade-off: it relies on how SwiftUI builds the menu bar item (the button lives
   in the app's status bar window), which Apple doesn't document. If that changes, the check stops
   matching and right-click falls back to opening the panel. It doesn't crash.
2. **Replace `MenuBarExtra` with an AppKit `NSStatusItem` and `NSPopover`.** Full, documented control
   of left vs right click, but the panel's hosting, dismissal and `menuOpen` tracking must be rebuilt,
   and SwiftUI `openWindow`/`openSettings` don't work reliably from content hosted outside a scene.
   Rejected: too much risk for one menu.
3. **Switch `MenuBarExtra` to `.menu` style.** Native menu on every click, but loses the panel. Rejected.

## Decided how

- `openSettings` is captured from a SwiftUI view inside the app's scenes (the status icon's label) and
  handed to the right-click controller, so Settings opens through the same SwiftUI path as the panel.

## Left to the builder

- Exactly how the status button is identified from the event (window/content-view lookup).
- Whether the button shows its pressed highlight while the menu is up.
