# Menu Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Antenna menu bar icon, a coloured menu, and radios folded into devices in Nearby networks.

**Architecture:** Each change is a pure WiFiCore function with tests plus a thin SwiftUI change in the WiFiUtil target, following the existing `MenuStatus.swift` / `ScanGrouping.swift` pattern.

**Tech Stack:** Swift 6.4, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-17-menu-polish-design.md`

## Global Constraints

- Every build and test command is prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `$T` means `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- No change to detection rules, findings, notifications, scanning or the Engine.
- Device grouping is display-only and never hides or merges a finding.
- The menu bar icon's colour means twin status only.
- Never "safe", "secure" or "verified" in user-facing text.
- `WiFiCore` imports only Foundation. Colours live in the app target; WiFiCore returns levels, not colours.
- Never launch the app without `--demo`. Launch only `--demo office` and `--demo wifiOff`. Never trigger a permission prompt.
- Do not stage or commit `Support/oui.tsv` (an owner-pending change in the working tree).
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Missing values** (nil RSSI-derived figures, nil latency, nil loss, blocked probes): level is `.unknown` and shows grey, never red. Test in Task 2.
2. **Flagged radio adjacent to a real router's addresses** must stay its own row. Test in Task 3.
3. **Two routers with consecutive address blocks** must not merge into one device. Test in Task 3.
4. **Location denied** (no names or addresses): grouping makes no devices and nothing crashes. Test in Task 3.
5. **No internet while a twin is flagged:** twin colour wins over the dimmed no-internet glyph. Test in Task 1.

---

### Task 1: Antenna icon

**Files:**
- Modify: `Sources/WiFiCore/MenuStatus.swift`, `Sources/WiFiUtil/StatusIcon.swift`
- Test: `Tests/WiFiCoreTests/MenuStatusTests.swift` (and the accessibility label tests, wherever they live)

**Interfaces — Produces:** `StatusTint` gains `case dimmed`. `statusGlyph(for:)` returns symbols per the spec's icon table. `statusAccessibilityLabel(for:)` decides from the snapshot state, not from symbol-name strings.

- [ ] **Step 1: Update tests first.** Expected glyphs:
  - off or not connected → `antenna.radiowaves.left.and.right.slash`, `.normal`
  - suspect → `antenna.radiowaves.left.and.right`, `.red`; worth a look → same, `.orange`
  - connected, verdict clear or note, internet `.offline` → `antenna.radiowaves.left.and.right.circle`, `.dimmed`
  - otherwise → `antenna.radiowaves.left.and.right`, `.normal`
  - suspect with internet offline → `.red` antenna (twin wins)
  - Accessibility labels keep their current texts ("WiFiUtil: not connected", "WiFiUtil: no internet", "WiFiUtil", and the warning-driven texts).
- [ ] **Step 2:** Run `$T --filter "MenuStatus|StatusAccessibility"`. Expected: FAIL on the old symbol names.
- [ ] **Step 3:** Implement. In `StatusIcon.swift`, `.dimmed` renders with `NSColor.secondaryLabelColor` through the existing palette path; `.normal` stays a template image.
- [ ] **Step 4:** Run the filter, then all of `$T`. Expected: PASS, no warnings.
- [ ] **Step 5:** Commit `feat: antenna menu bar icon`.

### Task 2: Coloured menu

**Files:**
- Create: `Sources/WiFiCore/Quality.swift`; Test: `Tests/WiFiCoreTests/QualityTests.swift`
- Modify: `Sources/WiFiUtil/MenuContentView.swift`

**Interfaces — Produces (WiFiCore):**

```swift
public enum QualityLevel: Int, Sendable, Comparable { case unknown, good, fair, poor }
public func signalLevel(rssi: Int) -> QualityLevel
public func signalBars(rssi: Int) -> Int                       // 1...4
public func snrLevel(_ snr: Int) -> QualityLevel
public func gatewayLatencyLevel(_ ms: Double?) -> QualityLevel
public func lossLevel(_ percent: Int?) -> QualityLevel
public func dnsLatencyLevel(_ ms: Double?) -> QualityLevel
public func internetLevel(_ status: InternetStatus) -> QualityLevel   // unknown → .unknown
public func gatewayLevel(_ net: ConnectivitySnapshot) -> QualityLevel // worse of latency and loss; .unknown if blocked or both nil
public func dnsLevel(_ net: ConnectivitySnapshot) -> QualityLevel     // .unknown if blocked
```

"Worse of" uses the order good < fair < poor and ignores `.unknown` unless both are unknown. `Comparable` order follows the raw values.

- [ ] **Step 1: Write tests** with every boundary from the spec table: RSSI −60 good, −61 fair, −70 fair, −71 poor; bars at −55 → 4, −56 → 3, −65 → 3, −66 → 2, −75 → 2, −76 → 1; SNR 25 good, 24 fair, 15 fair, 14 poor; gateway latency 19.9 good, 20 fair, 100 fair, 100.1 poor, nil unknown; loss 0 good, 1 fair, 5 fair, 6 poor, nil unknown; DNS 49.9 good, 50 fair, 200 fair, 200.1 poor; internet online good, captive portal fair, offline poor, unknown unknown; `gatewayLevel` with latency good + loss poor → poor, with `gatewayBlocked` → unknown; `dnsLevel` with `dnsBlocked` → unknown.
- [ ] **Step 2:** Run `$T --filter Quality`. Expected: FAIL, functions not defined.
- [ ] **Step 3:** Implement `Quality.swift`.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Restyle `MenuContentView`** to the approved mockup:
  - Warning lines move into one banner at the top of the menu (above the network name): rounded rectangle, background the verdict colour at 15 % opacity, text in that colour, `exclamationmark.triangle.fill` icon; red if any line is suspect, else orange. Keep the existing button action (`revealConnectedNetwork`).
  - Header row: network name (semibold 13) and a capsule chip "Wi-Fi N · band" (green at 15 % background, green text) when generation is known; band alone otherwise.
  - Section labels "Link" (`antenna.radiowaves.left.and.right`) and "Connectivity" (`globe`) in caption size, secondary colour.
  - Signal row: value plus four bars (rounded rectangles 4 pt wide, heights 5/8/11/14), filled bars in the level colour, the rest in `Color.secondary.opacity(0.3)`.
  - SNR row: value and the word "good" / "fair" / "poor" in the level colour.
  - Gateway, DNS and Internet rows: a leading 8 pt dot in the row's level colour; the Internet value text also in its level colour.
  - Colour mapping lives in one private helper: good → `.green`, fair → `.orange`, poor → `.red`, unknown → `.secondary`.
  - The "Wi-Fi is off", "Not connected" and Location-denied variants keep working; nothing else in the menu changes.
- [ ] **Step 6:** Run all of `$T`; `scripts/build-app.sh` exits 0; launch `--demo office` and `--demo wifiOff`, each alive after 5 s via `pgrep -x WiFiUtil`, then `pkill -x WiFiUtil`, no new crash report.
- [ ] **Step 7:** Commit `feat: coloured menu with quality levels`.

### Task 3: Radios grouped into devices

**Files:**
- Create: `Sources/WiFiCore/DeviceGrouping.swift`; Test: `Tests/WiFiCoreTests/DeviceGroupingTests.swift`
- Modify: `Sources/WiFiUtil/ScanWindowView.swift`

**Interfaces — Consumes:** `NetworkGroup`, `findings(for:in:)`, `MACAddress`, `AccessPoint`.

**Interfaces — Produces (WiFiCore):**

```swift
public struct DeviceGroup: Sendable, Identifiable {
    public var id: String                 // lowest address in the device
    public var accessPoints: [AccessPoint] // strongest first
    public var addressPattern: String     // e.g. "a4:b1:c2:00:01:x"
    public var bands: [Band]               // distinct, ascending
    public var strongestRSSI: Int
    public var isSingleRadio: Bool { accessPoints.count == 1 }
}
public func groupDevices(_ accessPoints: [AccessPoint], findings: [Finding]) -> [DeviceGroup]
public func devicesSummary(_ devices: [DeviceGroup]) -> String   // "6 radios on 2 devices", "1 radio on 1 device"
```

Algorithm (`groupDevices`), applied to one network group's access points:
1. Any access point with `bssid == nil`, or with at least one finding from `findings(for:in:)`, becomes its own single-radio device.
2. The rest are keyed by: byte 0 with `& ~0x02`, then bytes 1–4. Within a key, sort by byte 5 ascending; start a device at the lowest, add the next while `byte5 - deviceLowestByte5 <= 15`, otherwise start a new device.
3. Order devices: the one containing the strongest radio first, then by `strongestRSSI` descending; ties by `id`.
4. `addressPattern`: the lowest address's text with the last two hex digits replaced by `x` when the device has more than one radio; the full address otherwise. If byte 0 differs between radios (locally-administered bit), show the lowest address's byte 0.

- [ ] **Step 1: Write tests:**
  - tri-band router `a4:b1:c2:00:01:10/14/18` → one device of 3, pattern `a4:b1:c2:00:01:x`, bands [2.4, 5, 6]
  - locally-administered sibling `a6:b1:c2:00:01:11` with `a4:b1:c2:00:01:10` → one device
  - two routers `…:01:10,…:01:14` and `…:01:20,…:01:24` → two devices (span from 0x10 to 0x20 is 16)
  - a radio at `…:01:12` with a `vendorMismatch` finding beside `…:01:10/14` → three entries: one device of 2 plus the flagged radio alone
  - access points with `bssid == nil` → each alone, no crash
  - different byte 4 (`…:01:10` vs `…:02:10`) → separate
  - `devicesSummary` → "6 radios on 2 devices", "1 radio on 1 device", "2 radios on 2 devices"
  - empty input → `[]` and "0 radios on 0 devices"
- [ ] **Step 2:** Run `$T --filter DeviceGrouping`. Expected: FAIL, not defined.
- [ ] **Step 3:** Implement `DeviceGrouping.swift`.
- [ ] **Step 4:** Run the filter. Expected: PASS.
- [ ] **Step 5: Update `ScanWindowView`.**
  - Group header text "N access points" becomes `devicesSummary(...)` (for nameless groups keep "1 access point").
  - Inside an expanded network group, render `groupDevices(group.accessPoints, findings: snapshot.findings)`: a single-radio device renders as today's row; a multi-radio device renders a device row (chevron, `wifi.router` symbol, vendor of its lowest address or "–", `addressPattern`, bands joined with " · ", radio count, strongest signal) with `.help("Probably one device: same maker prefix and neighbouring addresses")`, and when expanded its radios render as today's rows, indented one more level.
  - Device expansion state is kept per device id; default collapsed, except the device containing the connected radio (`snapshot.link?.bssid`) in the connected group, which defaults to expanded.
  - Use `ForEach` identity by device id and by `bssid` (fall back to offset only for nil addresses).
  - Rows and their finding highlights are unchanged.
- [ ] **Step 6:** Run all of `$T`; `scripts/build-app.sh` exits 0; launch `--demo office` and `--demo wifiOff` as in Task 2.
- [ ] **Step 7:** Commit `feat: group radios into devices in Nearby networks`.
