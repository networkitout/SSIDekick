# Right-click Menu on the Menu Bar Icon Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click or Control-click on the SSIDekick menu bar icon shows a native menu with Settings… and Quit; left-click still opens the panel.

**Architecture:** Keep the SwiftUI `MenuBarExtra`. A local `NSEvent` monitor installed at launch catches mouse-downs on the app's `NSStatusBarButton`. When the click qualifies (a pure, tested rule in WiFiSystem), it pops up an `NSMenu` under the button and swallows the event. Settings opens through SwiftUI's `OpenSettingsAction`, which the status icon view captures.

**Tech Stack:** Swift 6.4 toolchain (WiFiUtil and WiFiSystem targets in Swift 5 language mode), SwiftUI, AppKit, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-24-status-item-right-click-design.md`

## Global Constraints

- Menu, exactly: `Settings…` (⌘,), separator, `Quit SSIDekick` (⌘Q).
- Left-click behaviour is unchanged; the panel's own Settings… and Quit buttons are unchanged.
- No AppKit import in WiFiSystem (it has none today); the pure rule takes plain Bools.
- All AppKit work on the main actor.
- Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Never launch the app without `--demo`, and skip launching if `pgrep -x SSIDekick` finds the owner's copy.

## Review Focus

- Command-drag to rearrange menu bar icons (left-click + ⌘) must not open the menu: pinned by `commandLeftClickIsNotMenu`.
- Control-click must behave like right-click: pinned by `controlLeftClickIsMenu`.
- Right-clicks in other windows (Nearby networks table, Settings) must pass through untouched: the monitor only acts when the hit view is an `NSStatusBarButton`. Check by hand (Task 2, Step 4).
- `install` must be idempotent: the status icon view re-runs often, and a second call must not stack monitors. Check by hand (Task 2, Step 4).
- Settings… when Settings is already open brings it to the front: activate the app, then open it. Check by hand.

---

### Task 1: Click rule

**Files:**
- Create: `Sources/WiFiSystem/StatusMenuClick.swift`
- Test: `Tests/WiFiSystemTests/StatusMenuClickTests.swift`

**Interfaces:**
- Produces: `public func isStatusMenuClick(rightButton: Bool, control: Bool, command: Bool) -> Bool`, true for any right-button click, or for a left click with Control held and Command not held.

- [ ] **Step 1: Write the failing tests** (`@Suite struct StatusMenuClickTests`, `import Testing`, `import WiFiSystem`)

```swift
@Test func rightClickIsMenu() { #expect(isStatusMenuClick(rightButton: true, control: false, command: false)) }
@Test func controlLeftClickIsMenu() { #expect(isStatusMenuClick(rightButton: false, control: true, command: false)) }
@Test func plainLeftClickIsNotMenu() { #expect(!isStatusMenuClick(rightButton: false, control: false, command: false)) }
@Test func commandLeftClickIsNotMenu() {
    #expect(!isStatusMenuClick(rightButton: false, control: false, command: true))
    #expect(!isStatusMenuClick(rightButton: false, control: true, command: true))
}
@Test func rightClickWithModifiersIsMenu() { #expect(isStatusMenuClick(rightButton: true, control: true, command: true)) }
```

- [ ] **Step 2: Run to see them fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StatusMenuClickTests`
Expected: build error, `isStatusMenuClick` not found.

- [ ] **Step 3: Implement `isStatusMenuClick` in `Sources/WiFiSystem/StatusMenuClick.swift`** with a doc comment saying why Command is excluded (⌘-drag rearranges menu bar icons).

- [ ] **Step 4: Run to see them pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StatusMenuClickTests`
Expected: 5 tests pass.

- [ ] **Step 5: Commit** `feat: rule for which menu bar clicks open the right-click menu`

### Task 2: Context menu controller and wiring

**Files:**
- Create: `Sources/WiFiUtil/StatusItemContextMenu.swift`
- Modify: `Sources/WiFiUtil/WindowSupport.swift` (`AppDelegate`: add `applicationDidFinishLaunching`)
- Modify: `Sources/WiFiUtil/StatusIcon.swift` (capture `openSettings`)

**Interfaces:**
- Consumes: `isStatusMenuClick(rightButton:control:command:)` from Task 1.
- Produces: `@MainActor final class StatusItemContextMenu: NSObject` with `static let shared`, `func install()` (idempotent: keeps one monitor), and `var openSettings: OpenSettingsAction?`.

- [ ] **Step 1: Implement `StatusItemContextMenu`**
  - `install()`: if no monitor yet, `NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])`.
  - In the handler: hit-test `event.locationInWindow` in `event.window?.contentView` and walk up superviews to an `NSStatusBarButton`. If none, or `isStatusMenuClick(rightButton: event.type == .rightMouseDown, control: flags.contains(.control), command: flags.contains(.command))` is false, return the event unchanged. Otherwise pop up the menu with `popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)` and return nil.
  - The menu is built each time: `Settings…` (key ",", ⌘) → `NSApp.activate()` then `openSettings?()`, or if that is nil, `NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)`. Separator. `Quit SSIDekick` (key "q", ⌘) → `NSApp.terminate(nil)`. Menu items target the controller (`@objc` actions).
- [ ] **Step 2: Wire it**
  - In `AppDelegate.applicationDidFinishLaunching(_:)`: call `StatusItemContextMenu.shared.install()`.
  - In `StatusIcon`: add `@Environment(\.openSettings) private var openSettings` and `.onAppear { StatusItemContextMenu.shared.openSettings = openSettings }` on the image.
- [ ] **Step 3: Build and run the whole suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -1` then `scripts/build-app.sh`
Expected: all tests pass (190 + 5); `build/SSIDekick.app` built and `codesign --verify --strict --deep` passes.

- [ ] **Step 4: Check by hand** in the built app, run with `--demo office` (or by the owner if their copy is running): right-click and Control-click show the menu and not the panel; left-click opens the panel; ⌘-drag still moves the icon; Settings… opens or fronts Settings; Quit quits; right-click in the Nearby networks window still behaves as before.

- [ ] **Step 5: Commit** `feat: right-click menu on the menu bar icon (Settings, Quit)`
