# WiFiUtil: icon, menu colour and device grouping

Date: 2026-11-17. Status: awaiting approval. Size: a small change.
Items marked **(builder's call)** were proposed by the design author and not explicitly chosen by the owner.

## Intent

After the first real launch the owner found the menu bar icon too close to Apple's own Wi-Fi icon, wanted colour in the menu so it is easier to read at a glance, and wanted the Nearby networks list to show which radios belong to the same physical device instead of a flat access-point count.

## Goals

1. Replace the Wi-Fi fan with the antenna glyph (owner's choice).
2. Colour the menu: quality figures coloured good / fair / poor, small section icons, and the twin warning as a tinted banner (owner approved the mockup).
3. In Nearby networks, fold radios that probably share one device into a device row (owner asked; approach proposed by the author).

## Non-goals and anti-goals

- No change to detection rules, findings, notifications or scan behaviour.
- Device grouping is display-only: it must never hide, merge or soften a finding.
- The icon's colour still means twin status only; link quality never colours the menu bar icon.
- Never "safe", "secure" or "verified" wording; a good figure is "good", not "safe".

## Approaches

- Icon: SF Symbol antenna family, tinted the same way the current glyph is. A custom-drawn glyph was considered and dropped: more work, no benefit the owner asked for.
- Colour: green / amber / red on quality figures with the warning moved to a banner (approved mockup). A blue-only quality scale was considered so amber and red stay reserved for security; dropped because engineers read green/amber/red for link quality instantly, and the banner plus a twin-only icon keeps the two meanings apart.
- Grouping: an address-proximity estimate within each network name (below). Using vendor plus channel pattern alone was dropped: it cannot tell two identical routers apart.

## Design

### Menu bar icon (owner's choice)

| State | Symbol | Tint |
|---|---|---|
| Clear or note | `antenna.radiowaves.left.and.right` | menu bar colour |
| Worth a look | same | orange |
| Suspect | same | red |
| Connected, no internet (and twin status clear) | `antenna.radiowaves.left.and.right.circle` | dimmed menu bar colour |
| Wi-Fi off or not connected | `antenna.radiowaves.left.and.right.slash` | menu bar colour |

Accessibility labels unchanged in meaning.

### Menu colour (owner approved the mockup; thresholds are the builder's call)

- Top: warning lines become one tinted banner (amber for worth a look, red for suspect) with a warning icon; connection lines ("Gateway changed") in the same banner.
- Header: network name, plus a chip with Wi-Fi generation and band.
- Section labels "Link" and "Connectivity" with small icons.
- Signal shows four bars: 4 at ≥ −55 dBm, 3 at ≥ −65, 2 at ≥ −75, else 1.
- Quality levels, each shown in green (good), amber (fair) or red (poor):

| Figure | Good | Fair | Poor |
|---|---|---|---|
| Signal (RSSI) | ≥ −60 dBm | −61 to −70 | < −70 |
| SNR | ≥ 25 dB | 15–24 | < 15 |
| Gateway latency | < 20 ms | 20–100 | > 100 |
| Gateway loss | 0 % | 1–5 % | > 5 % |
| DNS latency | < 50 ms | 50–200 | > 200 |
| Internet | online | captive portal | offline |

- Gateway and DNS rows carry a coloured dot: the worse of their latency and loss levels. Unknown, checking or blocked values are grey, never red.
- Colours use system colours so they work in light and dark mode.

### Device grouping in Nearby networks (builder's call, owner asked for the feature)

- Within one network name, two radios are treated as the same device when both addresses are known, their first byte matches after clearing the locally-administered bit, bytes 2–5 match, and the last byte is within 15 of the device's lowest last byte (devices are formed by sorting and starting a new device when the span would exceed 15).
- A radio with any finding is never folded into a device; it stays its own row with its existing highlight.
- A device with one radio is shown as a plain row, as today.
- Group header reads "N radios on M devices" (M counts single radios as devices).
- Device row: chevron, router icon, vendor, address with the varying part shown as `x`, bands present, radio count, strongest signal. Collapsed by default except in the connected network, where the device holding the connected radio is expanded.
- Wording says "probably one device" in the device row's help text; it is an estimate.
- Known miss: vendors that spread radio addresses further apart show as several devices. That is the safe way to be wrong.

## Left to the builder

File layout, exact spacing and fonts, chip and banner styling within the approved mockup, test fixtures.

## Testing

Pure functions in WiFiCore with tests: the icon state table, the quality levels and bar count with boundary values, and device grouping (multi-radio router folds, flipped locally-administered bit folds, two neighbouring routers 16 apart stay separate, flagged radio stays out, nameless and address-less radios stay single). Visual check by the owner in demo mode and on the real network.
