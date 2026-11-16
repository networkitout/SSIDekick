import Testing
@testable import WiFiCore

@Test func parsesUnpaddedAndDashed() {
    #expect(MACAddress("a4:b1:c2:0:1:f")?.description == "a4:b1:c2:00:01:0f")
    #expect(MACAddress("A4-B1-C2-00-01-0F") == MACAddress("a4:b1:c2:00:01:0f"))
}
@Test func rejectsMalformed() {
    for s in ["", "(incomplete)", "a4:b1:c2:00:01", "a4:b1:c2:00:01:0f:22", "zz:b1:c2:00:01:0f"] { #expect(MACAddress(s) == nil) }
}
@Test func locallyAdministeredBitAndOUI() {
    #expect(MACAddress("02:00:00:00:00:01")!.isLocallyAdministered)
    #expect(!MACAddress("a4:b1:c2:00:01:0f")!.isLocallyAdministered)
    #expect(MACAddress("a4:b1:c2:00:01:0f")!.oui == 0xA4B1C2)
}
@Test func weakestSecurity() {
    #expect(ap("x", nil, sec: [.wpa2, .wpa3]).weakestSecurity == .wpa2)
    #expect(ap("x", nil, sec: []).weakestSecurity == .open)
}
