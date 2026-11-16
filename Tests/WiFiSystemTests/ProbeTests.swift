import Foundation
import Testing
import WiFiCore
@testable import WiFiSystem

@Suite struct ProbeTests {
    @Test func parseARPReadsUnpaddedAddress() {
        #expect(parseARP("? (10.0.0.1) at a4:b1:c2:0:1:f on en0 ifscope [ethernet]\n")?.description == "a4:b1:c2:00:01:0f")
    }

    @Test func parseARPRejectsIncompleteAndMissingEntries() {
        #expect(parseARP("? (10.0.0.1) at (incomplete) on en0 ifscope [ethernet]\n") == nil)
        #expect(parseARP("10.0.0.1 (10.0.0.1) -- no entry\n") == nil)
        #expect(parseARP("") == nil)
    }

    @Test func icmpChecksumMatchesKnownValue() {
        #expect(icmpChecksum([0x08, 0x00, 0x00, 0x00, 0x12, 0x34, 0x00, 0x01]) == 0xE5CA)
    }

    @Test func classifyCaptiveMapsResponses() {
        #expect(classifyCaptive(status: 200, body: "<HTML><BODY>Success</BODY></HTML>") == .online)
        #expect(classifyCaptive(status: 200, body: "<html>Sign in</html>") == .captivePortal)
        #expect(classifyCaptive(status: 302, body: nil) == .captivePortal)
        #expect(classifyCaptive(status: nil, body: nil) == .offline)
    }

    @Test func validatedIPTrimsAndRejectsNonAddresses() {
        #expect(validatedIP(" 203.0.113.9\n") == "203.0.113.9")
        #expect(validatedIP("2001:db8::1") == "2001:db8::1")
        #expect(validatedIP("<html>") == nil)
        #expect(validatedIP("") == nil)
    }

    @Test func dnsQueryEncodesARecordQuery() {
        let query = dnsQuery(name: "apple.com", id: 0x1234)
        #expect(query.count == 27)
        #expect(Array(query.prefix(6)) == [0x12, 0x34, 0x01, 0x00, 0x00, 0x01])
        #expect(Array(query.suffix(15)) == [0x05, 0x61, 0x70, 0x70, 0x6c, 0x65, 0x03, 0x63, 0x6f, 0x6d,
                                            0x00, 0x00, 0x01, 0x00, 0x01])
    }

    @Test func networkConfigMapsServiceDictionaries() {
        let config = networkConfig(
            fromService: ["Router": "10.0.0.1", "Addresses": ["10.0.0.23"]],
            ipv6: ["Addresses": ["fe80::1c2b:3a4d:5e6f:7081"]],
            dns: ["ServerAddresses": ["10.0.0.1", "1.1.1.1"]]
        )
        #expect(config == NetworkConfig(gatewayIP: "10.0.0.1", dnsServers: ["10.0.0.1", "1.1.1.1"],
                                        ipv4: ["10.0.0.23"], ipv6: ["fe80::1c2b:3a4d:5e6f:7081"]))
    }

    @Test func networkConfigWithNoServiceIsEmpty() {
        let config = networkConfig(fromService: nil, ipv6: nil, dns: nil)
        #expect(config == NetworkConfig(gatewayIP: nil, dnsServers: [], ipv4: [], ipv6: []))
        #expect(config.gatewayIP == nil)
    }

    @Test func systemConfigForUnknownInterfaceIsEmptyAndChangesFinishOnDeinit() async {
        var source: SystemNetworkConfig? = SystemNetworkConfig(interfaceName: "nosuchif0")
        #expect(source?.current() == NetworkConfig(gatewayIP: nil, dnsServers: [], ipv4: [], ipv6: []))
        let changes = source!.changes
        source = nil
        for await _ in changes {}  // returns only because deinit finished the stream
    }

    @Test func loopbackPingReturnsLatency() async {
        let latency = await icmpPing("127.0.0.1", timeout: 1)
        #expect(latency != nil)
        #expect((latency ?? .infinity) < 100)
    }

    @Test func icmpPingRejectsNonIPv4WithoutSending() async {
        #expect(await icmpPing("not-an-ip", timeout: 1) == nil)
    }

    @Test func arpTableRejectsNonIPv4Input() async {
        let table = ARPNeighborTable()
        #expect(await table.hardwareAddress(forIPv4: "-a") == nil)
        #expect(await table.hardwareAddress(forIPv4: "10.0.0.1; ls") == nil)
        #expect(await table.hardwareAddress(forIPv4: "fe80::1") == nil)
    }

    @Test func dnsLatencyRejectsUnparseableServer() async {
        let prober = SystemProber()
        #expect(await prober.dnsLatency(server: "not-an-ip") == nil)
    }

    @Test func dnsServerAddressParsesScopedIPv6() {
        let scoped = dnsServerAddress("fe80::1%lo0")
        #expect(scoped?.family == AF_INET6)
        #expect((scoped?.scopeID ?? 0) != 0)
        #expect(dnsServerAddress("10.0.0.1")?.family == AF_INET)
        #expect(dnsServerAddress("apple.com") == nil)
        #expect(dnsServerAddress("") == nil)
    }
}
