import Foundation
import Testing
import WiFiCore
@testable import WiFiSystem

@Suite struct ProbeTests {
    @Test func parseARPReadsUnpaddedAddress() {
        #expect(parseARP("? (10.0.0.1) at a4:b1:c2:0:1:f on en0 ifscope [ethernet]\n", interface: "en0")?.description
                == "a4:b1:c2:00:01:0f")
    }

    @Test func parseARPRejectsIncompleteAndMissingEntries() {
        #expect(parseARP("? (10.0.0.1) at (incomplete) on en0 ifscope [ethernet]\n", interface: "en0") == nil)
        #expect(parseARP("10.0.0.1 (10.0.0.1) -- no entry\n", interface: "en0") == nil)
        #expect(parseARP("", interface: "en0") == nil)
    }

    @Test func parseARPIgnoresOtherInterfaces() {
        let output = """
        ? (10.0.0.1) at a4:b1:c2:0:1:f on en7 ifscope [ethernet]
        ? (10.0.0.1) at 50:c7:bf:1:2:3 on en0 ifscope [ethernet]

        """
        #expect(parseARP(output, interface: "en0") == MACAddress("50:c7:bf:01:02:03"))
        #expect(parseARP(output, interface: "en10") == nil)
        #expect(parseARP("? (10.0.0.1) at a4:b1:c2:0:1:f on en7 ifscope [ethernet]\n", interface: "en0") == nil)
    }

    @Test func interfaceNameValidation() {
        for good in ["en0", "en10", "lo0", "bridge100"] { #expect(isValidInterfaceName(good)) }
        for bad in ["", "en", "0en", "EN0", "en0 ", "en0;ls", "-a", "en0\n", "utun0-x"] { #expect(!isValidInterfaceName(bad)) }
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

    @Test func handSetDNSComesFromSetupServerAddresses() {
        let handSet = networkConfig(fromService: nil, ipv6: nil, dns: nil,
                                    setupDNS: ["ServerAddresses": ["192.168.1.2"]])
        #expect(handSet.dnsServersSetByHand)
        #expect(!networkConfig(fromService: nil, ipv6: nil, dns: nil, setupDNS: nil).dnsServersSetByHand)
        #expect(!networkConfig(fromService: nil, ipv6: nil, dns: nil,
                               setupDNS: ["ServerAddresses": [String]()]).dnsServersSetByHand)
        #expect(!networkConfig(fromService: nil, ipv6: nil, dns: nil).dnsServersSetByHand)
    }

    @Test(.timeLimit(.minutes(1)))
    func dnsLookupOverLoopbackParsesTheAnswer() async throws {
        let responder = try #require(LoopbackDNSResponder())
        let answer: [UInt8] = [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 8, 8, 8, 8]
        responder.answerOnce(with: answer)
        let result = await dnsLookup(name: "dns.google", server: "127.0.0.1", port: responder.port,
                                     interface: "lo0", timeout: 2)
        #expect(result == .answered(["8.8.8.8"]))
    }

    @Test(.timeLimit(.minutes(1)))
    func dnsLookupWaitsPastRepliesForOtherQueries() async throws {
        let responder = try #require(LoopbackDNSResponder())
        let answer: [UInt8] = [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x04, 8, 8, 4, 4]
        responder.answerOnce(with: answer, decoyFirst: true)
        let result = await dnsLookup(name: "dns.google", server: "127.0.0.1", port: responder.port,
                                     interface: "lo0", timeout: 2)
        #expect(result == .answered(["8.8.4.4"]))
    }

    @Test func dnsLookupRejectsUnparseableServer() async {
        #expect(await dnsLookup(name: "dns.google", server: "not-an-ip", interface: "lo0", timeout: 1) == .failed)
        #expect(await dnsLookup(name: "dns.google", server: "127.0.0.1", interface: "nosuchif0", timeout: 1) == .failed)
    }

    @Test(.timeLimit(.minutes(1)))
    func systemConfigForUnknownInterfaceIsEmptyAndChangesFinishOnDeinit() async {
        var source: SystemNetworkConfig? = SystemNetworkConfig(interfaceName: "nosuchif0")
        #expect(source?.current() == NetworkConfig(gatewayIP: nil, dnsServers: [], ipv4: [], ipv6: []))
        let changes = source!.changes
        source = nil
        for await _ in changes {}  // returns only because deinit finished the stream
    }

    @Test func loopbackPingReturnsLatency() async {
        let result = await icmpPing("127.0.0.1", interface: "lo0", timeout: 1)
        #expect(result.latencyMs != nil)
        #expect((result.latencyMs ?? .infinity) < 100)
    }

    @Test func icmpPingRejectsNonIPv4WithoutSending() async {
        #expect(await icmpPing("not-an-ip", interface: "lo0", timeout: 1) == .blocked)
    }

    @Test func probesOnUnknownInterfaceAreBlocked() async {
        #expect(await icmpPing("127.0.0.1", interface: "nosuchif0", timeout: 1) == .blocked)
        #expect(await dnsProbe(server: "127.0.0.1", interface: "nosuchif0", timeout: 1) == .blocked)
        #expect(await icmpPing("127.0.0.1", interface: "lo0;x", timeout: 1) == .blocked)
    }

    @Test func arpTableRejectsNonIPv4Input() async {
        let table = ARPNeighborTable(interfaceName: "lo0")
        #expect(await table.hardwareAddress(forIPv4: "-a") == nil)
        #expect(await table.hardwareAddress(forIPv4: "10.0.0.1; ls") == nil)
        #expect(await table.hardwareAddress(forIPv4: "fe80::1") == nil)
    }

    @Test func dnsLatencyRejectsUnparseableServer() async {
        let prober = SystemProber(interfaceName: "lo0")
        #expect(await prober.dnsLatency(server: "not-an-ip") == .blocked)
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

/// A UDP responder on 127.0.0.1 at a free port. It answers one query by echoing its header and question with the
/// reply flags set and one answer record appended, then closes. With `decoyFirst` it first sends the same reply
/// with the id changed, which the lookup must ignore.
private final class LoopbackDNSResponder: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32

    init?() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
        }
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard bound == 0, named == 0 else { close(fd); return nil }
        self.fd = fd
        self.port = UInt16(bigEndian: address.sin_port)
    }

    func answerOnce(with answer: [UInt8], decoyFirst: Bool = false) {
        DispatchQueue.global().async { [fd] in
            defer { close(fd) }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, 5_000) > 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let received = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &senderLength)
                    }
                }
            }
            guard received >= 12 else { return }
            var reply = Array(buffer.prefix(received))
            reply[2] = 0x81  // QR, recursion desired
            reply[3] = 0x80  // recursion available, no error
            reply[7] = 1     // one answer
            reply += answer
            func send(_ datagram: [UInt8]) {
                _ = datagram.withUnsafeBytes { bytes in
                    withUnsafePointer(to: &sender) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, bytes.baseAddress, bytes.count, 0, $0, senderLength)
                        }
                    }
                }
            }
            if decoyFirst {
                var decoy = reply
                decoy[1] ^= 0xFF
                send(decoy)
            }
            send(reply)
        }
    }
}
