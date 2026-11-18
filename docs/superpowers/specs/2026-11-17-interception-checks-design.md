# WiFiUtil: interception checks (DNS answers and HTTPS)

Date: 2026-11-17. Status: approved by the owner.
Items marked **(builder's call)** were proposed by the design author and not explicitly chosen by the owner.

## Intent

v1 answers "does this access point look like a copy?". The owner also wants "is this network tampering with my traffic?". An attacker who copies a network name, on a plane for example, usually does it to rewrite DNS answers or decrypt HTTPS. Two checks make that visible: whether the network's DNS server tells the truth about names whose answers are fixed, and whether HTTPS to apple.com reaches a certificate chain that ends at a root Apple ships.

## Goals

1. An always-visible **HTTPS (apple.com)** row in the menu's Connectivity section, saying whether HTTPS traffic can be decrypted on this path (owner's requirement: show it whatever the use case, so the user knows).
2. An always-visible **DNS answers** row saying whether the Wi-Fi network's DNS server answers truthfully.
3. A strong finding, **DNS answers tampered**, that turns the menu bar icon red, shows in the banner and sends a notification (owner agreed).
4. Both states appear in the copied report and in VoiceOver text.

## Non-goals

- Interception of sites other than apple.com. A network that intercepts only some sites will not be seen; the row says "apple.com" so it never claims more.
- Comparing DNS answers for ordinary sites (CDNs legitimately answer differently by location).
- Encrypted-DNS (DoH/DoT) lookups or any new DNS resolver as a reference.
- Blocking, fixing or bypassing anything. Warn only, as before.
- Remembering roots or networks across launches.

## Anti-goals

- **Never amber or red for an honest network that is merely captive.** Checks run only after the existing captive-portal check reports online.
- **"Can be decrypted" never changes the menu bar icon or notifies.** On a managed Mac it is permanent, and a permanent alert gets ignored (owner agreed).
- **Never "safe", "secure" or "verified".** A clean HTTPS result reads "Apple-trusted root", a clean DNS result "as expected".
- **No new third-party destinations beyond www.apple.com.** The DNS check only asks the network's own DNS server.

## Constraints

- Builds on the existing probe round in `Engine` (`refreshProbes` / `probeOnce`) and its safeguards: results are dropped if the session or network configuration changed during the probe, and probes run only while Wi-Fi is connected.
- The DNS check reuses the existing UDP DNS code in `DNSProbe.swift` (query builder, socket bound to the Wi-Fi interface, IPv4 and IPv6 servers, timeouts). It needs an answer parser it does not have today.
- The HTTPS check reuses the locked-down ephemeral `URLSession` setup in `HTTPProbes.swift` (no cache, no cookies, no redirects). Like the captive check, it follows the system default route, not necessarily Wi-Fi (accepted v1 ruling).
- Location denied: the rows still show, because they need no names; but findings are not raised without a network name (existing rule), so tampering then shows only as a red row.
- `WiFiCore` stays Foundation-only and colour-free; classification is pure and tested there.

## Approaches considered

| | Approach | Trade-off |
|---|---|---|
| **1 (chosen)** | Add both checks to the existing probe round, on a slower cadence | Inherits the session and stale-result safeguards that took two fix rounds to get right in v1 |
| 2 | Separate checker on its own timer | Needs a second copy of the session-tracking logic, the source of v1's worst bugs |
| 3 | Use the Mac's normal name lookup for DNS | A VPN or DNS profile changes who is asked, so the Wi-Fi network could be blamed for the VPN's behaviour |

## Decided by the owner

- An indicator of possible HTTPS decryption, shown whatever the use case.
- "Can be decrypted" is amber, in the menu row only.
- The HTTPS check uses apple.com.
- "DNS answers tampered" turns the icon red, shows in the banner and notifies.
- Approach 1.
- Filtered vs tampered: options (b) + (d). Known block answers are amber. Any other address is red unless the user hand-set their own DNS server.

## Design

### DNS answers check

Sent to the first DNS server configured for the Wi-Fi interface (the server the DNS latency probe already uses), over the existing bound UDP code, A-record queries only:

| Query | Expected |
|---|---|
| `one.one.one.one` | every A answer in {1.1.1.1, 1.0.0.1} |
| `dns.google` | every A answer in {8.8.8.8, 8.8.4.4} |
| `<12 random lowercase letters>.example.com` | NXDOMAIN, or no A answer |

Per-query classification (owner chose options **(b) + (d)**: filters stay amber, an unknown private answer on a joined network stays red):

- Known name answered with only expected addresses: as expected.
- Known name answered with NXDOMAIN, REFUSED, no A record, or only **block answers**: **filtered** (a parental, school, corporate or ad filter; not hijacking). Block answers are:
  - `0.0.0.0` and loopback `127.0.0.0/8`;
  - known filter block-page ranges, kept as one small table in WiFiCore. It starts with Cisco Umbrella / OpenDNS `146.112.61.0/24`. **(builder's call)** The builder may add other ranges only with a public source cited in a code comment.
- Known name answered with any other address (including a private address such as `172.19.0.1` or a LAN Pi-hole): **tampered**, except as below.
- **Hand-set DNS server (owner's option d):** the Wi-Fi service has DNS servers set by hand, and the server queried is a private address (RFC 1918, link-local or loopback). In that case, a would-be tampered answer becomes **filtered by your DNS server** (amber, no finding).
  - **(builder's call)** The exemption covers only a *private* hand-set server. Someone who hand-sets a public resolver such as 1.1.1.1 still gets red. A network can intercept port 53 traffic to 1.1.1.1 and lie, and a public resolver never sends block pages for these names.
- Made-up name answered with any A record: **rewritten**.
- No reply, a malformed reply or a send failure: unknown.

Overall state = worst of tampered > filtered / rewritten > as expected; unknown only if every query is unknown. When both filtered and rewritten apply, show rewritten. Answers whose transaction ID or question does not match are ignored. The address shown is the first unexpected A answer that is not a block answer.

| State | Row text | Level |
|---|---|---|
| as expected | `as expected` | good (green) |
| rewritten | `rewritten · made-up names resolve to <address>` | fair (amber) |
| filtered | `filtered · public DNS names blocked` | fair (amber) |
| filtered (hand-set server) | `filtered by your DNS server · <name> → <address>` | fair (amber) |
| tampered | `tampered · <name> → <address>` | poor (red) |
| unknown | `not checked` (portal or offline), `off` (setting off) or `no answer` | unknown (grey) |

**Detecting a hand-set server:** read `Setup:/Network/Service/<Wi-Fi service id>/DNS` → `ServerAddresses` from the dynamic store. Today `SystemNetworkConfig` reads only `State:` keys. A non-empty list means hand-set. The builder confirms on this Mac that setting DNS in System Settings › Wi-Fi › Details writes this key. If it does not, option (d) is left out, the builder reports it, and the rest still ships.

**Why `example.com` for the made-up name (builder's call):** names under `.invalid` may be answered locally by the resolver without ever reaching the part of the network that rewrites names, which would hide rewriting.

### HTTPS (apple.com) check

A GET to `https://www.apple.com/` on the locked-down session. The session delegate handles the server-trust challenge, records the result, then cancels the request (no body is downloaded).

- System trust evaluation fails: **rejected**.
- Evaluation passes and the chain's last certificate is one of the system's built-in anchors (`SecTrustCopyAnchorCertificates`, compared by certificate data): **direct**.
- Evaluation passes and the last certificate is not a built-in anchor: **can be decrypted**, with the root's subject summary (`SecCertificateCopySubjectSummary`).
- No TLS handshake (no route, timeout): unknown.

`SecTrustCopyAnchorCertificates` returns the system's default anchors (Apple's root store). Roots added by the user or by MDM are not in it. The builder does two things:

- cross-checks this once against `SecTrustSettingsCopyCertificates(kSecTrustSettingsDomainSystem)`, and stops and reports if the two disagree;
- loads the anchor set once per check, not cached across launches.

The owner does the live check: trusting a local inspection proxy's root (mitmproxy, for example) must show amber. Each check uses a fresh `URLSession` **(builder's call)**, so a reused TLS session can never skip the trust challenge.

| State | Row text | Level |
|---|---|---|
| direct | `direct · Apple-trusted root` | good (green) |
| can be decrypted | `can be decrypted · root "<name>"` | fair (amber) |
| rejected | `certificate rejected` | poor (red) |
| unknown | `not checked` / `no answer` | unknown (grey) |

"Certificate rejected" is red in the row but raises no finding **(builder's call)**: a captive portal the portal check missed can cause it, and the owner chose to keep icon alerts for DNS tampering. Revisit after real-world use.

### When the checks run

- Only while Wi-Fi is connected and the latest captive check says online.
- Once per session as soon as both hold, then every 300 s, and again when the Wi-Fi interface's DNS servers change **(builder's call on 300 s)**.
- Part of the probe round, so results are committed only if the session and network configuration are unchanged when they come back. A dropped result is retried on the next round.
- The three DNS queries run in parallel; the HTTPS check runs alongside them **(builder's call)**.
- Behind a captive portal or offline, both rows read `not checked`.
- Off switch in Settings: "Check DNS and HTTPS for interception" (default on), caption "Asks this network's DNS server about fixed names and opens apple.com." Off: both rows show `off`, grey, and nothing is sent.

### Finding

- New strong, connection-level signal `dnsTampered` (no access point address), raised for the connected network when the DNS state is tampered. Reason: `<name> resolved to <address> (expected <a> or <b>)`.
- It lives in `ConnectionMonitor` beside `gatewayChanged` and `dnsChanged`. It stays for the rest of the session and is cleared when the session ends, like those findings. It goes through the existing notification ledger (once per session).
- "Filtered" in any form, "rewritten" and "can be decrypted" raise no finding.
- Banner line: `DNS answers tampered`, alongside the existing gateway and DNS-server lines.
  - `connectionWarning` in `MenuStatus.swift` gains this case; today it handles only gateway and DNS-server changes.
  - Notification title: `DNS answers tampered: <network>`; `NotificationContent` gains the title case.
  - The accessibility label follows the banner wording.

### Menu and report

- Connectivity section gains two rows after Internet, in the same row style with a level dot: `DNS answers` and `HTTPS (apple.com)`.
- The copied report gains both lines with the same text.
- Demo mode gains four scenarios. Existing scenarios report as expected / direct.
  - `dnsTampered`: `dns.google → 172.19.0.1`; red row, red icon, banner, finding.
  - `dnsFiltered`: Umbrella block page; amber row only.
  - `dnsRewritten`: amber row only.
  - `httpsDecryptable`: amber row only, root "Demo Inspection CA".

## Left to the builder

- The DNS answer parser's shape (compression pointers must be handled), the random-label source, and the file layout.
- How the trust result passes from the URLSession delegate to the async caller.
- Exact Settings layout.
- Test fixtures, including captured DNS reply bytes.

## Testing

- Pure WiFiCore classification:
  - every row of both state tables;
  - the worst-of rule and filtered vs rewritten precedence;
  - `0.0.0.0`, `127.0.0.1` and `146.112.61.106` → filtered;
  - `172.19.0.1` → tampered;
  - `172.19.0.1` with a hand-set server `192.168.1.2` → filtered by your DNS server;
  - `172.19.0.1` with a hand-set server `1.1.1.1` → tampered;
  - a mix of one expected and one unexpected address → tampered.
- DNS answer parser on handmade replies: A answers, CNAME followed by A, compression pointers, NXDOMAIN, REFUSED, truncated and mismatched-ID replies.
- Engine with fakes: checks wait for online; run once per session then on the 300 s cadence; the result is dropped after a session change; off switch sends nothing; tampered raises one `dnsTampered` finding and one notification; can-be-decrypted raises none.
- No test contacts the network except loopback. The live check on apple.com and the real DNS server is the owner's, inside the signed app. So is the trusted-proxy check for amber HTTPS: adding a trusted root changes the Mac's security settings, so the builder must not do it.
