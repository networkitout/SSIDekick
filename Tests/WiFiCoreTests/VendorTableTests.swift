import Testing
@testable import WiFiCore

@Suite struct VendorTableTests {
    let table = VendorTable(tsv: "A4B1C2\tAcme, Inc.\n020000\tLocal Corp\n")

    @Test func resolvesKnownOUI() {
        #expect(table.vendor(for: MACAddress("a4:b1:c2:00:11:22")!) == "Acme, Inc.")
    }

    @Test func lowercaseKeyAccepted() {
        let t = VendorTable(tsv: "a4b1c2\tAcme\n")
        #expect(t.vendor(for: MACAddress("a4:b1:c2:00:11:22")!) == "Acme")
    }

    @Test func unknownOUIIsNil() {
        #expect(table.vendor(for: MACAddress("10:20:30:00:00:00")!) == nil)
    }

    @Test func locallyAdministeredIsNilEvenIfPresent() {
        #expect(table.vendor(for: MACAddress("02:00:00:00:00:01")!) == nil)
    }

    @Test func skipsBlankAndMalformedLines() {
        let t = VendorTable(tsv: "A4B1C2\tAcme\n\nnotab line\nZZZZZZ\tBad\nB0B1B2\tBeta\n")
        #expect(t.vendor(for: MACAddress("a4:b1:c2:00:00:00")!) == "Acme")
        #expect(t.vendor(for: MACAddress("b0:b1:b2:00:00:00")!) == "Beta")
    }

    @Test func emptyTableResolvesNothing() {
        #expect(VendorTable.empty.vendor(for: MACAddress("a4:b1:c2:00:00:00")!) == nil)
    }
}
