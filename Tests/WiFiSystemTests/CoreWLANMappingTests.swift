import Testing
import WiFiCore
@testable import WiFiSystem

/// Raw values come from CoreWLANTypes.h in the installed macOS SDK (CWChannelBand, CWPHYMode).
@Suite struct CoreWLANMappingTests {
    // CWChannelBand: Unknown = 0, 2GHz = 1, 5GHz = 2, 6GHz = 3.

    @Test func bandUsesKnownRawBand() {
        #expect(band(forChannelNumber: 6, cwBandRawValue: 1) == .ghz2_4)
        #expect(band(forChannelNumber: 36, cwBandRawValue: 2) == .ghz5)
        #expect(band(forChannelNumber: 37, cwBandRawValue: 3) == .ghz6)
    }

    @Test func bandRawValueWinsOverChannelNumber() {
        // 6 GHz channel 5 overlaps the 2.4 GHz numbering; the reported band decides.
        #expect(band(forChannelNumber: 5, cwBandRawValue: 3) == .ghz6)
    }

    @Test func bandFallsBackOnChannelNumberWhenRawBandUnknown() {
        #expect(band(forChannelNumber: 1, cwBandRawValue: 0) == .ghz2_4)
        #expect(band(forChannelNumber: 14, cwBandRawValue: 0) == .ghz2_4)
        #expect(band(forChannelNumber: 32, cwBandRawValue: 0) == .ghz5)
        #expect(band(forChannelNumber: 177, cwBandRawValue: 0) == .ghz5)
    }

    @Test func bandFallsBackOnChannelNumberForUnlistedRawBand() {
        #expect(band(forChannelNumber: 11, cwBandRawValue: 42) == .ghz2_4)
        #expect(band(forChannelNumber: 149, cwBandRawValue: -1) == .ghz5)
    }

    @Test func bandOutsideTheTwoLowerRangesIsSixGHz() {
        // Channel numbers outside 1...14 and 32...177 are used only in 6 GHz.
        #expect(band(forChannelNumber: 181, cwBandRawValue: 0) == .ghz6)
        #expect(band(forChannelNumber: 233, cwBandRawValue: 0) == .ghz6)
        #expect(band(forChannelNumber: 21, cwBandRawValue: 0) == .ghz6)
    }

    // CWPHYMode: None = 0, 11a = 1, 11b = 2, 11g = 3, 11n = 4, 11ac = 5, 11ax = 6, 11be = 7.

    @Test func generationForNoneIsNil() {
        #expect(generation(fromPHYModeRawValue: 0) == nil)
    }

    @Test func generationFor11a() {
        #expect(generation(fromPHYModeRawValue: 1) == .wifi2)
    }

    @Test func generationFor11b() {
        #expect(generation(fromPHYModeRawValue: 2) == .wifi1)
    }

    @Test func generationFor11g() {
        #expect(generation(fromPHYModeRawValue: 3) == .wifi3)
    }

    @Test func generationFor11n() {
        #expect(generation(fromPHYModeRawValue: 4) == .wifi4)
    }

    @Test func generationFor11ac() {
        #expect(generation(fromPHYModeRawValue: 5) == .wifi5)
    }

    @Test func generationFor11ax() {
        #expect(generation(fromPHYModeRawValue: 6) == .wifi6)
    }

    @Test func generationFor11be() {
        #expect(generation(fromPHYModeRawValue: 7) == .wifi7)
    }

    @Test func generationForUnlistedValueIsNil() {
        #expect(generation(fromPHYModeRawValue: 8) == nil)
        #expect(generation(fromPHYModeRawValue: -1) == nil)
    }

    // CWSecurity: None = 0, WEP = 1, WPAPersonal = 2, WPAPersonalMixed = 3, WPA2Personal = 4, Personal = 5,
    // DynamicWEP = 6, WPAEnterprise = 7, WPAEnterpriseMixed = 8, WPA2Enterprise = 9, Enterprise = 10,
    // WPA3Personal = 11, WPA3Enterprise = 12, WPA3Transition = 13, OWE = 14, OWETransition = 15, Unknown = NSIntegerMax.

    @Test func securityNoneAndOWEAreOpen() {
        #expect(securityMode(fromSecurityRawValue: 0) == .open)
        #expect(securityMode(fromSecurityRawValue: 14) == .open)
        #expect(securityMode(fromSecurityRawValue: 15) == .open)
    }

    @Test func securityWEPVariantsAreWEP() {
        #expect(securityMode(fromSecurityRawValue: 1) == .wep)
        #expect(securityMode(fromSecurityRawValue: 6) == .wep)
    }

    @Test func securityWPAVariantsAreWPA() {
        #expect(securityMode(fromSecurityRawValue: 2) == .wpa)
        #expect(securityMode(fromSecurityRawValue: 3) == .wpa)
        #expect(securityMode(fromSecurityRawValue: 7) == .wpa)
        #expect(securityMode(fromSecurityRawValue: 8) == .wpa)
    }

    @Test func securityWPA2VariantsAreWPA2() {
        #expect(securityMode(fromSecurityRawValue: 4) == .wpa2)
        #expect(securityMode(fromSecurityRawValue: 5) == .wpa2)
        #expect(securityMode(fromSecurityRawValue: 9) == .wpa2)
        #expect(securityMode(fromSecurityRawValue: 10) == .wpa2)
    }

    @Test func securityWPA3VariantsAreWPA3() {
        #expect(securityMode(fromSecurityRawValue: 11) == .wpa3)
        #expect(securityMode(fromSecurityRawValue: 12) == .wpa3)
        #expect(securityMode(fromSecurityRawValue: 13) == .wpa3)
    }

    @Test func securityUnknownIsNil() {
        #expect(securityMode(fromSecurityRawValue: Int.max) == nil)
        #expect(securityMode(fromSecurityRawValue: 16) == nil)
    }
}
