# Interception Checks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two new Connectivity rows, "DNS answers" and "HTTPS (apple.com)". Tampered DNS answers raise a strong `dnsTampered` finding: red icon, banner and notification.

**Architecture:** Classification and wording are pure WiFiCore functions. WiFiSystem gains a DNS answer parser, a lookup, a TLS trust check and hand-set DNS detection, all behind the `Prober` and `NetworkConfigSource` protocols. The Engine runs both checks inside the existing probe round (`probeOnce`), so they inherit the epoch and config-unchanged guards. The finding is raised by `ConnectionMonitor`.

**Tech Stack:** Swift 6.4, SwiftUI, Security framework, SystemConfiguration, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-17-interception-checks-design.md`

## Global Constraints

- Prefix every build and test command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. `$T` means `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`.
- `WiFiCore` imports only Foundation and stays colour-free. It returns `QualityLevel`, and the app target maps levels to colours.
- User-facing text must never say "safe", "secure" or "verified". Row texts are exactly the strings in Task 1.
- "Can be decrypted", "filtered" (both forms) and "rewritten" never raise a finding, never change the menu bar icon and never notify. Only `tampered` raises `dnsTampered`.
- No amber or red while the captive check is not `.online`. The rows then read `not checked`.
- The only new network destinations are the Wi-Fi network's own DNS server and `https://www.apple.com/`.
- No test contacts the network except loopback.
- Never change the Mac's network settings, DNS settings or trust settings (no adding roots, no `networksetup`, no `security add-trusted-cert`). Any live check that needs those is the owner's.
- Never launch the app without `--demo`. Before launching, run `pgrep -x WiFiUtil`. If a WiFiUtil you did not start is running, skip the launch and say so. Stop only your own pid with `kill <pid>`.
- Stage files by name. Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **Captive portal or offline:** both rows read `not checked` and no lookup or HTTPS request is sent. Test in Task 5.
2. **Network change while a check is in flight:** the result is dropped, and the new network never shows the old network's red row or finding. Test in Task 5.
3. **Hand-set public resolver (`1.1.1.1`) answering `172.19.0.1`:** red, not amber. A hand-set private server gives amber. Test in Task 1.
4. **HTTPS timeout or no route:** grey `no answer`, never red `certificate rejected`. Test in Task 1 (`classifyTLS`) and Task 4.
5. **Location denied with tampered DNS:** the red row shows, no finding or notification is raised, and nothing crashes. Test in Task 5.

---

### Task 1: Classification and wording (WiFiCore)

**Files:**
- Create: `Sources/WiFiCore/Interception.swift`
- Test: `Tests/WiFiCoreTests/InterceptionTests.swift`

**Interfaces — Produces:**

```swift
public enum DNSLookup: Sendable, Equatable {
    case answered([String])   // NOERROR; the A-record addresses in answer order (may be empty)
    case nameError            // NXDOMAIN
    case refused              // REFUSED
    case failed               // timeout, send failure, malformed reply, SERVFAIL or any other rcode
}

public enum DNSAnswersState: Sendable, Equatable {
    case notChecked, off, noAnswer
    case asExpected
    case filtered
    case filteredByYourServer(name: String, address: String)
    case rewritten(address: String)
    case tampered(name: String, address: String, expected: [String])
}

public enum HTTPSState: Sendable, Equatable {
    case notChecked, off, noAnswer
    case direct
    case decryptable(root: String)
    case rejected
}

public enum InterceptionCheck {
    public static let knownNames: [(name: String, expected: [String])] =
        [("one.one.one.one", ["1.1.1.1", "1.0.0.1"]), ("dns.google", ["8.8.8.8", "8.8.4.4"])]
    public static let interval: TimeInterval = 300
    public static let httpsURL = "https://www.apple.com/"
}

public func madeUpName() -> String                 // 12 random a–z letters + ".example.com"
public func isPrivateAddress(_ ip: String) -> Bool  // 10/8, 172.16/12, 192.168/16, 169.254/16, 127/8, fc00::/7, fe80::/10 (scope suffix "%en0" allowed), ::1
public func isBlockAnswer(_ ip: String) -> Bool     // 0.0.0.0, 127/8, 146.112.61.0/24
public func classifyDNS(known: [(name: String, lookup: DNSLookup)], madeUp: DNSLookup,
                        handSetPrivateServer: Bool) -> DNSAnswersState
public func classifyTLS(trustPassed: Bool?, rootIsSystemAnchor: Bool, rootName: String?) -> HTTPSState
public func dnsAnswersText(_ state: DNSAnswersState) -> String
public func dnsAnswersLevel(_ state: DNSAnswersState) -> QualityLevel
public func httpsText(_ state: HTTPSState) -> String
public func httpsLevel(_ state: HTTPSState) -> QualityLevel
```

`classifyDNS` rules. `known` pairs each lookup with the name it asked about; expected addresses come from `InterceptionCheck.knownNames`.
- **Per known name:**
  - `.answered` with no addresses, `.nameError` or `.refused` → filtered.
  - `.answered` where every address is expected → as expected.
  - Otherwise, take the addresses that are not expected:
    - if all of them are block answers → filtered;
    - if not, take the first one that is not a block answer. It is tampered, or `filteredByYourServer` when `handSetPrivateServer` is true.
  - `.failed` → unknown.
- **Made-up name:** `.answered` with at least one address → `rewritten(address: first)`. `.answered([])` or `.nameError` → as expected. `.refused` or `.failed` → unknown.
- **Overall:** the worst result by rank: tampered 4 > rewritten 3 > filteredByYourServer 2 > filtered 1 > asExpected 0. Among several tampered names, the first in `known` order wins. If every query is unknown → `.noAnswer`.

`classifyTLS`:
- `trustPassed == nil` → `.noAnswer`;
- `false` → `.rejected`;
- `true` with `rootIsSystemAnchor` → `.direct`;
- `true` without it → `.decryptable(root: rootName ?? "unknown")`.

Exact texts and levels:

| State | Text | Level |
|---|---|---|
| asExpected | `as expected` | good |
| rewritten(a) | `rewritten · made-up names resolve to <a>` | fair |
| filtered | `filtered · public DNS names blocked` | fair |
| filteredByYourServer(n, a) | `filtered by your DNS server · <n> → <a>` | fair |
| tampered(n, a, _) | `tampered · <n> → <a>` | poor |
| notChecked / off / noAnswer | `not checked` / `off` / `no answer` | unknown |
| direct | `direct · Apple-trusted root` | good |
| decryptable(r) | `can be decrypted · root "<r>"` | fair |
| rejected | `certificate rejected` | poor |
| HTTPS notChecked / off / noAnswer | `not checked` / `off` / `no answer` | unknown |

- [ ] **Step 1: Write the failing tests** in `InterceptionTests.swift`, one `@Test` per line below. `ok` means both known names answered with their expected addresses and the made-up name `.nameError`.
  - `ok` → `.asExpected`
  - dns.google `.answered(["0.0.0.0"])` → `.filtered`; the same for `127.0.0.1` and `146.112.61.106`
  - dns.google `.nameError` → `.filtered`; `.refused` → `.filtered`; `.answered([])` → `.filtered`
  - dns.google `.answered(["172.19.0.1"])`, `handSetPrivateServer: false` → `.tampered(name: "dns.google", address: "172.19.0.1", expected: ["8.8.8.8", "8.8.4.4"])`
  - the same with `handSetPrivateServer: true` → `.filteredByYourServer(name: "dns.google", address: "172.19.0.1")`
  - dns.google `.answered(["8.8.8.8", "172.19.0.1"])` → tampered with address `172.19.0.1`
  - dns.google `.answered(["0.0.0.0", "172.19.0.1"])` → tampered with address `172.19.0.1`
  - made-up `.answered(["10.20.0.80"])`, known names fine → `.rewritten(address: "10.20.0.80")`
  - made-up rewritten plus dns.google filtered → `.rewritten`
  - made-up rewritten plus dns.google tampered → `.tampered`
  - every lookup `.failed` → `.noAnswer`; one known name fine and the rest `.failed` → `.asExpected`
  - `isPrivateAddress`: true for `10.0.0.1`, `172.16.0.1`, `172.31.255.1`, `192.168.1.2`, `169.254.3.4`, `127.0.0.1`, `fd00::1`, `fe80::1%en0`, `::1`; false for `172.32.0.1`, `1.1.1.1`, `8.8.8.8`, `2606:4700::1111`, `not an ip`
  - `isBlockAnswer`: true for `0.0.0.0`, `127.0.0.53`, `146.112.61.110`; false for `146.112.62.1`, `192.168.1.2`
  - `madeUpName()` matches `^[a-z]{12}\.example\.com$`, and two calls differ
  - `classifyTLS`: `(nil, false, nil)` → `.noAnswer`; `(false, true, "x")` → `.rejected`; `(true, true, "ISRG")` → `.direct`; `(true, false, "Zscaler Root CA")` → `.decryptable(root: "Zscaler Root CA")`
  - every row of the text-and-level table above
  - no text contains "safe", "secure" or "verified" (loop over every state)
- [ ] **Step 2:** Run `$T --filter Interception`. Expected: FAIL to compile, symbols not defined.
- [ ] **Step 3:** Implement `Interception.swift`.
  - Parse addresses with `inet_pton` (on macOS, Foundation re-exports it); add no new import.
  - Keep the block-page ranges in one `private let` table. Add a comment citing Cisco Umbrella's public documentation of its block-page addresses. Add no other range unless you can cite a public source for it.
- [ ] **Step 4:** Run `$T --filter Interception`. Expected: PASS. Then run `$T`. Expected: all pass, no warnings.
- [ ] **Step 5:** Commit `feat: classify DNS answers and HTTPS trust`.

### Task 2: Finding, banner, notification and report (WiFiCore)

**Files:**
- Modify: `Sources/WiFiCore/Findings.swift`, `Sources/WiFiCore/ConnectionMonitor.swift`, `Sources/WiFiCore/Snapshot.swift`, `Sources/WiFiCore/MenuStatus.swift`, `Sources/WiFiCore/NotificationContent.swift`, `Sources/WiFiCore/ReportFormatter.swift`
- Test: `Tests/WiFiCoreTests/ConnectionMonitorTests.swift`, `MenuStatusTests.swift`, `NotificationContentTests.swift`, `ReportFormatterTests.swift`, `SnapshotTests.swift`

**Interfaces — Consumes:** Task 1's `DNSAnswersState`, `HTTPSState`, `dnsAnswersText`, `httpsText`.

**Interfaces — Produces:**
- `Signal.dnsTampered`, strength `.strong`, listed with the strong cases.
- `ConnectivitySnapshot` gains `public var dnsAnswers: DNSAnswersState` and `public var https: HTTPSState`. Both are `.notChecked` in `init()`.
- `ConnectionState` gains `public var dnsAnswers: DNSAnswersState`, with a new trailing init parameter `dnsAnswers: DNSAnswersState = .notChecked`. Existing call sites compile unchanged.
- `public func dnsAnswersWarning(for snapshot: Snapshot) -> WarningLine?` returns `WarningLine(text: "DNS answers tampered", verdict: .suspect)` when `snapshot.findings` has a `dnsTampered` finding for `snapshot.link?.ssid`; nil otherwise.
- `warningLines(for:)` returns twin, connection, then DNS answers, nils dropped.

Behaviour:
- `ConnectionMonitor.update`: when `connection.dnsAnswers` is `.tampered(name, address, expected)`, raise one connection-level finding:
  - `Finding(signal: .dnsTampered, ssid: connection.ssid, bssid: nil, reason: "<name> resolved to <address> (expected <expected joined by " or ">).")`
  - It is deduplicated by the existing `raise`, and it stays until the session ends.
  - Later non-tampered states do not remove it. `endSession` clears it, as it clears the others.
- `connectionWarning` keeps its texts. A session whose only connection finding is `dnsTampered` returns nil there; the DNS answers line covers it.
- `notificationContent`: `.dnsTampered` → title `DNS answers tampered: <ssid>`.
- `formatReport`: two lines right after the `Internet:` line: `DNS answers: <dnsAnswersText>` and `HTTPS (apple.com): <httpsText>`.

- [ ] **Step 1: Write failing tests:**
  - **ConnectionMonitor:**
    - a tampered state raises exactly one `dnsTampered` with reason `dns.google resolved to 172.19.0.1 (expected 8.8.8.8 or 8.8.4.4).` and `bssid == nil`;
    - two more updates while tampered add no second finding;
    - a later `.asExpected` keeps it;
    - a new SSID clears it;
    - `.filtered`, `.filteredByYourServer` and `.rewritten` raise nothing.
  - **MenuStatus:**
    - a snapshot whose only finding is a connection-level `dnsTampered` gives `connectedVerdict` `.suspect` (via `networkVerdict`) and `warningLines` == `[WarningLine(text: "DNS answers tampered", verdict: .suspect)]`;
    - `statusGlyph` is a red antenna;
    - `statusAccessibilityLabel` is `"WiFiUtil: DNS answers tampered"`;
    - with `gatewayChanged` also present, the lines are `["Gateway changed", "DNS answers tampered"]`.
  - **NotificationContent:** the title for `dnsTampered` on "InflightWiFi" is `DNS answers tampered: InflightWiFi`.
  - **ReportFormatter:**
    - a snapshot with `dnsAnswers = .tampered(name: "dns.google", address: "172.19.0.1", expected: [...])` and `https = .decryptable(root: "Demo Inspection CA")` contains the lines `DNS answers: tampered · dns.google → 172.19.0.1` and `HTTPS (apple.com): can be decrypted · root "Demo Inspection CA"`;
    - a default snapshot contains `DNS answers: not checked`.
  - **Snapshot:** `ConnectivitySnapshot()` has both new fields `.notChecked`.
- [ ] **Step 2:** Run `$T --filter "ConnectionMonitor|MenuStatus|NotificationContent|ReportFormatter|Snapshot"`. Expected: FAIL.
- [ ] **Step 3:** Implement. Fix any exhaustive `switch` over `Signal` elsewhere; the compiler lists them.
- [ ] **Step 4:** Run the filter, then all of `$T`. Expected: PASS, no warnings.
- [ ] **Step 5:** Commit `feat: dnsTampered finding, banner line, notification and report lines`.

### Task 3: DNS lookup and hand-set DNS detection (WiFiSystem)

**Files:**
- Create: `Sources/WiFiSystem/DNSMessage.swift`
- Modify: `Sources/WiFiSystem/DNSProbe.swift`, `Sources/WiFiSystem/Sources.swift`, `Sources/WiFiSystem/SystemProber.swift`, `Sources/WiFiSystem/NetworkConfig.swift`, `Sources/WiFiSystem/DemoSources.swift` (DemoProber only), `Tests/WiFiSystemTests/EngineTests.swift` (FakeProber only)
- Test: `Tests/WiFiSystemTests/DNSMessageTests.swift`, `Tests/WiFiSystemTests/ProbeTests.swift`

**Interfaces — Consumes:** `DNSLookup` (Task 1).

**Interfaces — Produces:**
- `func parseDNSResponse(_ bytes: [UInt8], id: UInt16, name: String) -> DNSLookup?`, internal to `DNSMessage.swift`.
  - Returns nil when the reply is not for this query: the id differs, the QR bit is clear, or the question name or type does not match (case-insensitive). The caller keeps waiting.
  - Returns `.failed` for a truncated or malformed reply and for rcode other than 0, 3 and 5.
  - rcode 3 → `.nameError`, 5 → `.refused`.
  - rcode 0 → `.answered(A addresses in order)`. It walks every answer record, follows compression pointers (with a loop guard), skips CNAMEs and other types, and keeps only type 1, class 1, rdlength 4.
- `func dnsLookup(name: String, server: String, interface: String, timeout: TimeInterval) async -> DNSLookup`, in `DNSProbe.swift`. It uses the same bound, connected UDP socket as `dnsProbe`. Factor the shared socket setup out so both use it, and keep `dnsProbe`'s behaviour unchanged.
- `Prober` gains `func dnsLookup(name: String, server: String) async -> DNSLookup`. `SystemProber` calls the free function with `timeout: 2`.
- `NetworkConfig` gains `public var dnsServersSetByHand: Bool`, with a new trailing init parameter `dnsServersSetByHand: Bool = false`.
- `networkConfig(fromService:ipv6:dns:setupDNS:)`: `setupDNS` is the `Setup:/Network/Service/<id>/DNS` dictionary. `dnsServersSetByHand` is true when its `ServerAddresses` is a non-empty `[String]`. `SystemNetworkConfig.current()` reads that key for the same service id.
- Test doubles:
  - `FakeProber` gains `var lookups: [String: DNSLookup]`. Names under `example.com` use the key `"madeUp"`. The default answers every name as expected, with `"madeUp"` → `.nameError`.
  - It also gains `var lookupCount = 0`.
  - `DemoProber` returns the same defaults; Task 5 adds scenarios.

- [ ] **Step 1: Write failing tests** in `DNSMessageTests.swift`, using handmade byte arrays (build them with `dnsQuery(name:id:)` as the header and question, then append answers):
  - one A record `8.8.8.8` → `.answered(["8.8.8.8"])`
  - two A records → both, in order
  - CNAME then A, with the A's name a compression pointer to the CNAME target → `.answered([that A])`
  - an AAAA record only → `.answered([])`
  - rcode 3 → `.nameError`; rcode 5 → `.refused`; rcode 2 → `.failed`
  - a wrong id → nil; QR clear → nil; a different question name → nil; the question name in different case → parsed
  - truncated in the middle of an answer → `.failed`
  - a compression pointer pointing at itself → `.failed`, no hang
- [ ] **Step 2:** Add to `ProbeTests.swift`:
  - `networkConfig(... setupDNS: ["ServerAddresses": ["192.168.1.2"]])` → `dnsServersSetByHand == true`;
  - `setupDNS: nil` → false; `["ServerAddresses": []]` → false.
- [ ] **Step 3:** Add a loopback test that binds a UDP socket on `127.0.0.1` and answers one query with a canned reply. Then check that `dnsLookup(name: "dns.google", server: "127.0.0.1", interface: "lo0", timeout: 2)` returns `.answered(["8.8.8.8"])`. If the existing probe tests already have a loopback responder, reuse it.
- [ ] **Step 4:** Run `$T --filter "DNSMessage|Probe"`. Expected: FAIL.
- [ ] **Step 5:** Implement.
- [ ] **Step 6:** Run the filter, then all of `$T`. Expected: PASS, no warnings.
- [ ] **Step 7: Read-only check.** Run `scutil <<< "show Setup:/Network/Service/<Wi-Fi service id>/DNS"`, finding the service id via `scutil <<< "list State:/Network/Service/[^/]+/IPv4"`. Record the output in the report. Do not change any setting. The owner's live check confirms that setting DNS by hand fills this key.
- [ ] **Step 8:** Commit `feat: DNS answer parser, lookup and hand-set DNS detection`.

### Task 4: HTTPS trust check (WiFiSystem)

**Files:**
- Create: `Sources/WiFiSystem/HTTPSCheck.swift`
- Modify: `Sources/WiFiSystem/Sources.swift`, `Sources/WiFiSystem/SystemProber.swift`, `Sources/WiFiSystem/DemoSources.swift` (DemoProber only), `Tests/WiFiSystemTests/EngineTests.swift` (FakeProber only)
- Test: `Tests/WiFiSystemTests/HTTPSCheckTests.swift`

**Interfaces — Consumes:** `HTTPSState`, `classifyTLS`, `InterceptionCheck.httpsURL` (Task 1).

**Interfaces — Produces:**
- `Prober` gains `func httpsCheck() async -> HTTPSState`. It returns only `.direct`, `.decryptable`, `.rejected` or `.noAnswer`.
- `FakeProber` gains `var httpsResult: HTTPSState = .direct` and `var httpsCount = 0`. `DemoProber` returns `.direct`.
- `func systemAnchorData() -> Set<Data>`: the data of every certificate from `SecTrustCopyAnchorCertificates`, loaded on each call.
- `func httpsCheck(url: URL, timeout: TimeInterval) async -> HTTPSState`. `SystemProber` calls it with `InterceptionCheck.httpsURL` and `timeout: 5`.

Approach:
- Each call makes a fresh ephemeral `URLSession` with the same lockdown as `HTTPProbes` (no cache, no cookies), plus a delegate, and invalidates the session afterwards.
- On the `NSURLAuthenticationMethodServerTrust` challenge, the delegate:
  - runs `SecTrustEvaluateWithError`;
  - on success, takes the last certificate of `SecTrustCopyCertificateChain`, checks whether its data is in `systemAnchorData()`, and reads `SecCertificateCopySubjectSummary`;
  - records the result through `classifyTLS`;
  - answers `.cancelAuthenticationChallenge`, so no body is downloaded.
- If the task ends with no challenge seen (no route, timeout), the result is `.noAnswer`.
- The continuation resumes exactly once.

- [ ] **Step 1: Write failing tests:**
  - **`anchorsAreTheSystemStore`:**
    - `systemAnchorData()` has more than 100 entries;
    - every entry is also in the data of `SecTrustSettingsCopyCertificates(.system)`;
    - `SecTrustSettingsCopyCertificates(.user)` and `(.admin)` share no entry with it. Treat `errSecNoTrustSettings` as empty.
    - If this test fails on this Mac, stop and report BLOCKED. The spec rests on it.
  - **`noRouteIsNoAnswer`:** `httpsCheck(url: URL(string: "https://127.0.0.1:1/")!, timeout: 2)` → `.noAnswer`. Nothing listens on port 1, so the connection is refused.
- [ ] **Step 2:** Run `$T --filter HTTPSCheck`. Expected: FAIL to compile.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the filter, then all of `$T`. Expected: PASS, no warnings.
- [ ] **Step 5:** Commit `feat: HTTPS trust check against the system root store`.

### Task 5: Engine scheduling, setting and demo scenarios (WiFiSystem)

**Files:**
- Modify: `Sources/WiFiSystem/Engine.swift`, `Sources/WiFiSystem/StoredSettings.swift`, `Sources/WiFiSystem/DemoSources.swift`
- Test: `Tests/WiFiSystemTests/EngineTests.swift`, `Tests/WiFiSystemTests/StoredSettingsTests.swift`

**Interfaces — Consumes:** Tasks 1–4.

**Interfaces — Produces:**
- `EngineSettings` gains `public var interceptionChecksEnabled: Bool`, with init parameter `interceptionChecksEnabled: Bool = true`.
- `SettingsKey.interceptionChecksEnabled = "interceptionChecksEnabled"`. `loadEngineSettings` reads it, and a missing value means true.
- `DemoScenario` gains `dnsTampered`, `dnsFiltered`, `dnsRewritten` and `httpsDecryptable`. All four use the `office` Wi-Fi, config and neighbours, and their prober answers are:
  - `dnsTampered`: dns.google → `.answered(["172.19.0.1"])`;
  - `dnsFiltered`: both known names → `.answered(["146.112.61.106"])`;
  - `dnsRewritten`: the made-up name → `.answered(["10.20.0.80"])`;
  - `httpsDecryptable`: `httpsCheck` → `.decryptable(root: "Demo Inspection CA")`.
  - All other answers are as expected, and HTTPS is `.direct`.

Engine behaviour, inside `probeOnce` after `internetCheck`:
- **Setting off:** do not call `dnsLookup` or `httpsCheck`; commit `dnsAnswers = .off`, `https = .off`.
- **Captive check not `.online`:** call neither; commit both `.notChecked`.
- **Otherwise the checks are due when:** no check has completed this session, or `now() - lastCheck >= InterceptionCheck.interval`, or `current.dnsServers` differs from the servers used by the last committed check. If not due, leave both fields as they are.
- **When due:**
  - With a DNS server, look up both known names and `madeUpName()` on `current.dnsServers.first`, then classify with `handSetPrivateServer: current.dnsServersSetByHand && isPrivateAddress(server)`.
  - With no DNS server, `dnsAnswers = .notChecked`.
  - Run `httpsCheck()` too. Run the three lookups and the HTTPS check concurrently.
- **Commit:** results go through the existing epoch and config guards, together with the other probe values. Only a committed check sets `lastCheck` and the servers used. A dropped result leaves the check due.
- **Session state:** `lastCheck` and the servers used are cleared wherever the Engine resets `snapshot.connectivity` (session end, session change, not connected).
- **Turning the setting off:** both fields become `.off` at once.
- **Turning it back on:** the fields become `.notChecked`, `lastCheck` clears, and the probe nap wakes.
- **Raising the finding:** `recompute` passes `snapshot.connectivity.dnsAnswers` into `ConnectionState(dnsAnswers:)`.

- [ ] **Step 1: Write failing Engine tests**, using `FakeProber`, `FakeConfig` and `Clock`:
  - **Not online:** with internet `.captivePortal`, after a probe both fields are `.notChecked` and `lookupCount == 0`, `httpsCount == 0`. Make `FakeProber.internetCheck`'s status settable for this.
  - **First check:** when online, one probe gives `.asExpected` and `.direct`, with `lookupCount == 3` and `httpsCount == 1`.
  - **Cadence:**
    - a second probe 10 s later sends nothing more;
    - at +300 s it runs again;
    - changing `FakeConfig.dnsServers` triggers it at once.
  - **Setting off:** no lookups, both `.off`. Turning it back on and probing runs the checks.
  - **Tampered:** dns.google `.answered(["172.19.0.1"])` gives a red row state. Exactly one `dnsTampered` finding reaches `onNewFindings`, and three more probes past +300 s produce no second notification.
  - **Hand-set server:** `dnsServersSetByHand: true` with server `192.168.1.2` gives `.filteredByYourServer` and no finding. With server `1.1.1.1` it gives `.tampered`.
  - **Can be decrypted:** `httpsResult = .decryptable(root: "X")` gives the state and no finding.
  - **Session change mid-check:** start a probe whose lookup is held by a gate, change the SSID before releasing it, then release. The new session shows `.notChecked` and no `dnsTampered`, and the next probe runs the check for the new session. Reuse the existing `Gate` helper pattern.
  - **Location denied:** a tampered result shows `.tampered` in `snapshot.connectivity.dnsAnswers`, while `snapshot.findings` stays empty and `onNewFindings` is never called.
  - **Demo scenarios:**
    - `makeDemoEngine(.dnsTampered)` after one probe has a `dnsTampered` finding and `connectedVerdict == .suspect`;
    - `.dnsFiltered` has `.filtered` and no finding;
    - `.httpsDecryptable` has `https == .decryptable(root: "Demo Inspection CA")`;
    - `.office` has `.asExpected` and `.direct`.
- [ ] **Step 2:** Add to `StoredSettingsTests`: a missing key → true; a stored `false` → false.
- [ ] **Step 3:** Run `$T --filter "Engine|StoredSettings"`. Expected: FAIL.
- [ ] **Step 4:** Implement.
- [ ] **Step 5:** Run the filter, then all of `$T`. Expected: PASS, no warnings, and every pre-existing Engine test unchanged.
- [ ] **Step 6:** Commit `feat: run interception checks in the probe round`.

### Task 6: Menu rows and Settings toggle (app target)

**Files:**
- Modify: `Sources/WiFiUtil/MenuContentView.swift`, `Sources/WiFiUtil/SettingsView.swift`

**Interfaces — Consumes:** `dnsAnswersText`, `dnsAnswersLevel`, `httpsText`, `httpsLevel` (Task 1); `SettingsKey.interceptionChecksEnabled` (Task 5).

- [ ] **Step 1:** In `connectivityBlock`, right after the Internet row, add `row("DNS answers", dnsAnswersText(net.dnsAnswers), level: dnsAnswersLevel(net.dnsAnswers), tintValue: true)` and `row("HTTPS (apple.com)", httpsText(net.https), level: httpsLevel(net.https), tintValue: true)`. Long values truncate in the middle on one line; they must not widen the menu.
- [ ] **Step 2:** In `SettingsView`, after the public IP caption, add:
  - `Toggle("Check DNS and HTTPS for interception", isOn: ...)` bound to `@AppStorage(SettingsKey.interceptionChecksEnabled)`, default true;
  - the caption `Asks this network's DNS server about fixed names and opens apple.com.` in the same caption style;
  - `.onChange` calling `apply()`.
- [ ] **Step 3:** Run all of `$T`. `scripts/build-app.sh` must exit 0 with no warnings.
- [ ] **Step 4: Demo launches.** Run `--demo office`, `--demo dnsTampered`, `--demo dnsFiltered` and `--demo httpsDecryptable`, one at a time, following the launch rule in Global Constraints. Each must still be running after 5 s, and no new crash report may appear in `~/Library/Logs/DiagnosticReports`.
- [ ] **Step 5:** Commit `feat: DNS answers and HTTPS rows, interception setting`.

## Owner's live checks (after the branch is built)

- On your normal network: `DNS answers as expected` and `HTTPS (apple.com) direct · Apple-trusted root`.
- Set this Mac's Wi-Fi DNS by hand to a private address (or a Pi-hole). Check that `scutil` shows `Setup:/…/DNS`, and that a blocked name reads `filtered by your DNS server`.
- Trust a local inspection proxy's root (mitmproxy, for example) and route through it. HTTPS must show amber `can be decrypted · root "mitmproxy"`. Remove the root afterwards.
- Behind a captive portal, both rows read `not checked`.
- On a normal network, a made-up `*.example.com` name is not answered (otherwise every network would show amber rewritten).
- With the Mac on Ethernet and Wi-Fi joined to a captive guest network, both rows read `not checked`.
