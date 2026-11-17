import Testing
import WiFiCore

private func link(_ ssid: String? = "Net") -> LinkSnapshot {
    LinkSnapshot(ssid: ssid, bssid: MACAddress("a4:b1:c2:00:00:01"), rssi: -58, noise: -92, txRateMbps: 573,
                 channel: Channel(number: 44, band: .ghz5, widthMHz: 80), generation: .wifi6,
                 security: .wpa2, countryCode: "US")
}

private func finding(_ signal: Signal, ssid: String = "Net", bssid: String? = "a4:b1:c2:00:00:02") -> Finding {
    Finding(signal: signal, ssid: ssid, bssid: bssid.flatMap { MACAddress($0) }, reason: "r")
}

private func snapshot(state: WiFiState = .connected, link: LinkSnapshot? = link(), internet: InternetStatus = .online,
                      findings: [Finding] = [], verdict: Verdict = .clear) -> Snapshot {
    var connectivity = ConnectivitySnapshot()
    connectivity.internet = internet
    return Snapshot(state: state, locationAuthorized: true, link: link, connectivity: connectivity, scan: [],
                    scanTime: nil, scanError: nil, findings: findings, connectedVerdict: verdict)
}

@Suite struct StatusGlyphTests {
    @Test func clearConnectionIsPlainWiFi() {
        #expect(statusGlyph(for: snapshot()) == StatusGlyph(symbol: "wifi", tint: .normal))
    }
    @Test func noteStaysPlain() {
        #expect(statusGlyph(for: snapshot(verdict: .note)) == StatusGlyph(symbol: "wifi", tint: .normal))
    }
    @Test func worthALookIsOrange() {
        #expect(statusGlyph(for: snapshot(verdict: .worthALook)) == StatusGlyph(symbol: "wifi", tint: .orange))
    }
    @Test func suspectIsRed() {
        #expect(statusGlyph(for: snapshot(verdict: .suspect)) == StatusGlyph(symbol: "wifi", tint: .red))
    }
    @Test func offIsSlashed() {
        #expect(statusGlyph(for: snapshot(state: .off, link: nil)) == StatusGlyph(symbol: "wifi.slash", tint: .normal))
    }
    @Test func notConnectedIsSlashed() {
        #expect(statusGlyph(for: snapshot(state: .notConnected, link: nil)).symbol == "wifi.slash")
    }
    @Test func connectedWithoutLinkIsSlashed() {
        #expect(statusGlyph(for: snapshot(link: nil)).symbol == "wifi.slash")
    }
    @Test func offlineShowsExclamationMark() {
        #expect(statusGlyph(for: snapshot(internet: .offline))
                == StatusGlyph(symbol: "wifi.exclamationmark", tint: .normal))
    }
    @Test func captivePortalAndUnknownAreNotOffline() {
        #expect(statusGlyph(for: snapshot(internet: .captivePortal)).symbol == "wifi")
        #expect(statusGlyph(for: snapshot(internet: .unknown)).symbol == "wifi")
    }
    @Test func twinColourWinsOverExclamationMark() {
        #expect(statusGlyph(for: snapshot(internet: .offline, verdict: .worthALook))
                == StatusGlyph(symbol: "wifi", tint: .orange))
        #expect(statusGlyph(for: snapshot(internet: .offline, verdict: .suspect))
                == StatusGlyph(symbol: "wifi", tint: .red))
    }
}

@Suite struct TwinWarningTests {
    @Test func noLineBelowWorthALook() {
        #expect(twinWarning(for: snapshot()) == nil)
        #expect(twinWarning(for: snapshot(findings: [finding(.countryMismatch)], verdict: .note)) == nil)
    }
    @Test func noLineWhenNotConnected() {
        #expect(twinWarning(for: snapshot(state: .off, link: nil, findings: [finding(.securityMismatch)],
                                          verdict: .suspect)) == nil)
    }
    @Test func oneSuspectTwin() {
        let s = snapshot(findings: [finding(.securityMismatch)], verdict: .suspect)
        #expect(twinWarning(for: s)?.text == "⚠ 1 suspect twin")
    }
    @Test func countsEachSuspectAddressOnce() {
        let s = snapshot(findings: [
            finding(.securityMismatch, bssid: "a4:b1:c2:00:00:02"),
            finding(.clonedAddress, bssid: "a4:b1:c2:00:00:02"),
            finding(.securityMismatch, bssid: "a4:b1:c2:00:00:03"),
            finding(.vendorMismatch, bssid: "a4:b1:c2:00:00:04"),
            finding(.securityMismatch, ssid: "Other", bssid: "a4:b1:c2:00:00:05"),
        ], verdict: .suspect)
        #expect(twinWarning(for: s)?.text == "⚠ 2 suspect twins")
    }
    @Test func worthALookCount() {
        let s = snapshot(findings: [
            finding(.vendorMismatch, bssid: "a4:b1:c2:00:00:02"),
            finding(.countryMismatch, bssid: "a4:b1:c2:00:00:03"),
            finding(.beaconMismatch, bssid: "a4:b1:c2:00:00:03"),
            finding(.countryMismatch, bssid: "a4:b1:c2:00:00:04"),
        ], verdict: .worthALook)
        #expect(twinWarning(for: s)?.text == "⚠ 2 worth a look")
    }
    @Test func connectionLevelFindingIsNeverATwin() {
        let s = snapshot(findings: [finding(.gatewayChanged, bssid: nil)], verdict: .suspect)
        #expect(twinWarning(for: s) == nil)
        #expect(warningLines(for: s).map(\.text) == ["⚠ Gateway changed"])
        #expect(warningLines(for: s).map(\.verdict) == [.suspect])
    }
    @Test func dnsAndBothConnectionLines() {
        let dns = snapshot(findings: [finding(.dnsChanged, bssid: nil)], verdict: .suspect)
        #expect(warningLines(for: dns).map(\.text) == ["⚠ DNS servers changed"])
        let both = snapshot(findings: [finding(.dnsChanged, bssid: nil), finding(.gatewayChanged, bssid: nil)],
                            verdict: .suspect)
        #expect(warningLines(for: both).map(\.text) == ["⚠ Gateway and DNS changed"])
    }
    @Test func twinAndConnectionLinesTogether() {
        let s = snapshot(findings: [finding(.vendorMismatch), finding(.gatewayChanged, bssid: nil)], verdict: .suspect)
        #expect(warningLines(for: s).map(\.text) == ["⚠ 1 worth a look", "⚠ Gateway changed"])
        #expect(warningLines(for: s).map(\.verdict) == [.worthALook, .suspect])
        let red = snapshot(findings: [finding(.clonedAddress), finding(.dnsChanged, bssid: nil)], verdict: .suspect)
        #expect(warningLines(for: red).map(\.text) == ["⚠ 1 suspect twin", "⚠ DNS servers changed"])
    }
    @Test func noteLevelAddressGivesNoTwinLine() {
        let s = snapshot(findings: [finding(.countryMismatch), finding(.gatewayChanged, bssid: nil)], verdict: .suspect)
        #expect(warningLines(for: s).map(\.text) == ["⚠ Gateway changed"])
    }
}

@Suite struct StatusAccessibilityTests {
    @Test func labelsFollowTheWarningLines() {
        #expect(statusAccessibilityLabel(for: snapshot()) == "WiFiUtil")
        #expect(statusAccessibilityLabel(for: snapshot(state: .off, link: nil)) == "WiFiUtil: not connected")
        #expect(statusAccessibilityLabel(for: snapshot(internet: .offline)) == "WiFiUtil: no internet")
        #expect(statusAccessibilityLabel(for: snapshot(findings: [finding(.securityMismatch)], verdict: .suspect))
                == "WiFiUtil: 1 suspect twin")
        #expect(statusAccessibilityLabel(for: snapshot(findings: [finding(.gatewayChanged, bssid: nil)], verdict: .suspect))
                == "WiFiUtil: Gateway changed")
        #expect(statusAccessibilityLabel(for: snapshot(findings: [finding(.vendorMismatch),
                                                                 finding(.dnsChanged, bssid: nil)], verdict: .suspect))
                == "WiFiUtil: 1 worth a look; DNS servers changed")
    }
}
