# WiFiUtil: design

Date: 2026-11-16. Status: awaiting approval.

Items marked **(builder's call)** were decided by the design author, not by the owner, and can be overturned.

## Intent

A macOS menu bar app for a network engineer's own use. It does two jobs:

1. **Evil-twin tripwire.** Warn when the Wi-Fi network you are on (or about to join) has an impostor: something broadcasting the same name that does not look like it belongs with the other access points. The motivating case is in-flight, hotel or café Wi-Fi where an attacker copies the network name to intercept traffic.
2. **Link and connectivity at a glance.** Show how good the current Wi-Fi link is and whether the network behind it works, without opening several separate tools.

## Goals

- Flag suspicious same-name access points, and say why each one was flagged so the engineer can judge it.
- Notice suspicious changes while connected: access point, gateway hardware address, DNS servers.
- Show live link quality and a small set of connectivity checks in the menu.
- Show every network in range, grouped by name, with per-access-point detail and channel crowding.
- Copy a plain-text report of the current state to the clipboard.

## Non-goals for v1

- Speed tests, packet capture, signal-over-time graphs, logging to a file.
- Remembering access points across app launches (twin detection works within one run).
- A command-line tool. The module split below keeps it possible later.
- Mac App Store distribution, sandboxing, notarisation.

## Anti-goals

These would make the app a failure even if everything else works.

- **Never acts on the network.** Warn only. It never disconnects, forgets or joins a network, and never changes any network setting.
- **Never noisy on a normal network.** An office or mesh network with many same-vendor access points under one name must produce no warning.
- **Never claims certainty.** A careful attacker who clones everything exactly can evade passive detection. The wording is "suspect", with reasons, and never "safe" or "verified".
- **Never scans continuously.** A full scan takes seconds and can briefly disturb the live connection.
- **No telemetry.** Nothing leaves the machine except the connectivity probes listed below.

## Constraints

- macOS hides network names and access point addresses from apps without Location Services permission. The app requests it on first run and must behave sensibly when it is denied.
- Location permission is granted to a signed app bundle. The Mac has one Apple Development signing certificate, which is enough for local use.
- Xcode is installed at `/Applications/Xcode.app`, but `xcode-select` points at the Command Line Tools. Do not change that setting; set `DEVELOPER_DIR` per command.
- Swift 6.4 on macOS 27.2. Minimum deployment target macOS 15 **(builder's call)**.
- Apple frameworks only, no third-party packages **(builder's call)**.
- The project folder is empty and is not yet a git repository.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **A (chosen)** | Single SwiftUI menu bar app, not sandboxed, detection logic in its own tested module | Free access to gateway hardware address, pings and DNS settings. Cannot ship on the Mac App Store as built. |
| B | Sandboxed, App Store-ready app | Some checks (gateway hardware address in particular) become harder or uncertain, for a store listing nobody asked for. |
| C | Core engine plus command-line tool, menu bar app on top | Scriptable, but macOS does not grant Location permission to bare command-line tools, so it needs extra bundling work. Deferred. |

The owner picked A. Electron and Python were dropped early: neither reaches Apple's Wi-Fi data without a native helper.

## Decided by the owner

- Native Swift and SwiftUI, using Apple's CoreWLAN framework.
- Lives in the menu bar.
- Warn only when a twin is found.
- v1 scope as listed under Goals and Non-goals.
- Approach A.

## How it is put together (builder's call)

Three layers, so the detection rules can be tested without a radio.

- **WiFiCore**: pure Swift, no system frameworks. Data models, twin detector, vendor lookup, channel crowding, report text.
- **WiFiSystem**: talks to macOS. Wi-Fi interface and scans (CoreWLAN), Location permission (CoreLocation), network settings (SystemConfiguration), probes. Each source sits behind a protocol so the app can run on fake data.
- **App**: SwiftUI `MenuBarExtra` with a window-style popover, the scan window, settings, notifications. No Dock icon (`LSUIElement`).

Packaging: a Swift package plus a small script that assembles and signs the `.app` bundle, since there is no Xcode project generator installed. If that proves awkward for Location permission or launch-at-login, fall back to a hand-made Xcode project.

A **demo mode** (launch argument) feeds the app canned scenarios, including a twin. It is needed because a real evil twin cannot be produced on demand for testing.

## Twin detection

Networks in range are grouped by name. Hidden networks (no name) are listed but not grouped. Each access point in a group is compared with its siblings, and each finding carries a strength and a one-line reason.

| Signal | Strength | Notes |
|---|---|---|
| Security differs from siblings (open among encrypted, or weaker mode) | Strong | |
| Same access point address seen on two channels within one scan | Strong | Points to a cloned address. Across separate scans it may just be a channel change, so that does not count. |
| Gateway hardware address changes while on the same network | Strong | Connected network only |
| DNS servers change while on the same network with no reconnect | Strong | Connected network only |
| Vendor differs from every sibling | Medium | Needs at least two siblings sharing a vendor |
| Appeared after you joined and is louder than your access point | Medium | Connected network only. "After you joined" means absent from the first full scan completed after joining. |
| Connection moved to an access point that already carries a finding | Medium | Connected network only |
| Software-generated (locally administered) address when siblings have none | Weak | Some real multi-network access points do this |
| Country code, beacon interval or Wi-Fi generation differs from siblings | Weak | |

Scoring **(builder's call)**: one strong signal makes an access point **suspect (red)**. One medium, or two weak, makes it **worth a look (amber)**. A single weak signal is shown only as a note in the scan window. A group with a single access point can only raise the connected-network signals.

A plain roam between two clean same-vendor access points raises nothing.

## What the engineer sees

Menu bar icon **(builder's call)**: a Wi-Fi glyph. Its colour is the twin status of the connected network only: normal, amber or red. A slashed glyph means Wi-Fi is off or not connected; a small exclamation badge means connected with no internet.

```
 InflightWiFi           ⚠ 1 suspect twin
 Signal −58 dBm · Noise −92 · SNR 34
 Ch 44 (5 GHz, 80 MHz) · Wi-Fi 6 · 573 Mbps
 Security: Open         AP: a4:…:1f (Vendor)
 ─────────────────────────────────────
 Gateway 10.0.0.1    4 ms   0% loss
 DNS 10.0.0.1       22 ms
 Internet            ✓  68 ms · captive portal: no
 IP 10.0.3.17 · Public 203.0.113.9
 ─────────────────────────────────────
 Nearby networks…
 Scan now          Copy report
 Settings…         Quit
```

Clicking the warning line opens the scan window with the affected group expanded.

**Scan window.** Networks grouped by name, the connected group first, then groups with findings, then by strongest signal. Each row: access point address, vendor, channel and width, band, signal, security, Wi-Fi generation, findings. Suspect rows are highlighted and show their reasons. A second tab shows channel crowding per band: how many access points sit on or overlap each channel and how strong they are.

**Notification.** One per new finding at amber or red on the connected network, with the reason. No repeats for the same finding during the same connection.

**Other states.** Location denied: link numbers still show; names and addresses are replaced by one line explaining why, with a button that opens the right System Settings pane. Wi-Fi off or not connected: the menu says so and nearby networks can still be scanned.

**Settings.** Background scan interval (off, 30 s, 60 s, 5 min), public IP lookup on or off, launch at login.

## Data and timing (builder's call)

| What | Source | How often |
|---|---|---|
| Signal, noise, rate, channel, Wi-Fi generation, security, access point address | Current interface | Every 1 s while the menu is open, every 10 s otherwise, and on system Wi-Fi change events |
| Nearby networks | Full scan | On "Scan now", on joining or changing access point, and on the background interval (default 60 s). System cached results are used in between. |
| Gateway address, DNS servers, own IP addresses (v4 and v6) | System network settings | On change events |
| Gateway hardware address | System neighbour table | With each gateway probe |
| Gateway latency and loss | Unprivileged ICMP ping | Every 5 s while the menu is open, every 30 s otherwise; loss over the last 20 probes |
| DNS latency | Direct query to the first configured server | Same as gateway |
| Internet and captive portal | Apple's captive portal check URL | Same as gateway |
| Public IP | One HTTPS request to a public "what is my IP" service | When the menu opens, cached per connection, can be switched off |
| Vendor name | Bundled snapshot of the IEEE vendor registry | Offline lookup |

SNR is signal minus noise. The public interface does not expose every radio detail (stream count, for example); v1 shows what it exposes and does not use private interfaces.

## Left to the builder

- Exact file layout, bundle identifier, icon artwork.
- Which public IP service to use, and its timeout.
- Compact format for the vendor table and how it is refreshed. Fetching the registry file is a download and needs the owner's go-ahead at build time.
- Wording of findings and notifications, within the "suspect, with reasons" rule.
- Probe timeouts and how failures are displayed.

## Testing

- **WiFiCore** unit tests on fixture scans: multi-access-point office (must be silent), mesh, single access point, open twin beside an encrypted network, different-vendor twin, cloned address on two channels, newcomer after join, gateway and DNS change.
- **Demo mode** walks the app through the same scenarios for a visual check of icon, menu, scan window and notification.
- **Live check** on the real network: numbers agree with macOS's own Wi-Fi details (Option-click the Wi-Fi menu), probes react when the network is unplugged upstream, Location denied state reads correctly.
