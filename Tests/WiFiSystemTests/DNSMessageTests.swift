import Foundation
import Testing
import WiFiCore
@testable import WiFiSystem

/// A reply to `dnsQuery(name:id:)`: the query's header and question with the reply flags set, then `answers`.
private func reply(name: String = "dns.google", id: UInt16 = 0x1234, qr: Bool = true, rcode: UInt8 = 0,
                   answers: [[UInt8]] = []) -> [UInt8] {
    var bytes = dnsQuery(name: name, id: id)
    bytes[2] = (qr ? 0x80 : 0x00) | 0x01  // QR, recursion desired
    bytes[3] = 0x80 | rcode               // recursion available, rcode
    bytes[6] = UInt8(answers.count >> 8)
    bytes[7] = UInt8(answers.count & 0xFF)
    for answer in answers { bytes += answer }
    return bytes
}

/// One resource record. The default owner name is a pointer to the question name at offset 12.
private func record(name: [UInt8] = [0xC0, 0x0C], type: UInt16 = 1, rdata: [UInt8]) -> [UInt8] {
    name + [UInt8(type >> 8), UInt8(type & 0xFF), 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C,
            UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)] + rdata
}

@Suite struct DNSMessageTests {
    @Test func oneARecord() {
        let bytes = reply(answers: [record(rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .answered(["8.8.8.8"]))
    }

    @Test func twoARecordsInOrder() {
        let bytes = reply(answers: [record(rdata: [8, 8, 4, 4]), record(rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .answered(["8.8.4.4", "8.8.8.8"]))
    }

    @Test func cnameThenAWithCompressedName() {
        // Question "dns.google" is 12 bytes at offset 12, then type and class: the answers start at 28.
        // The CNAME's rdata starts at 28 + 2 (name) + 10 (fixed fields) = 40.
        let target: [UInt8] = [5] + Array("alias".utf8) + [3] + Array("net".utf8) + [0]
        let cname = record(type: 5, rdata: target)
        let a = record(name: [0xC0, 40], rdata: [10, 1, 2, 3])
        let bytes = reply(answers: [cname, a])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .answered(["10.1.2.3"]))
    }

    @Test func aaaaOnlyIsAnEmptyAnswer() {
        let bytes = reply(answers: [record(type: 28, rdata: [UInt8](repeating: 0x20, count: 16))])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .answered([]))
    }

    @Test func rcodes() {
        #expect(parseDNSResponse(reply(rcode: 3), id: 0x1234, name: "dns.google") == .nameError)
        #expect(parseDNSResponse(reply(rcode: 5), id: 0x1234, name: "dns.google") == .refused)
        #expect(parseDNSResponse(reply(rcode: 2), id: 0x1234, name: "dns.google") == .failed)
    }

    @Test func repliesForOtherQueriesAreIgnored() {
        let a = record(rdata: [8, 8, 8, 8])
        #expect(parseDNSResponse(reply(id: 0x9999, answers: [a]), id: 0x1234, name: "dns.google") == nil)
        #expect(parseDNSResponse(reply(qr: false, answers: [a]), id: 0x1234, name: "dns.google") == nil)
        #expect(parseDNSResponse(reply(name: "one.one.one.one", answers: [a]), id: 0x1234, name: "dns.google") == nil)
    }

    @Test func questionTypeMustBeA() {
        var bytes = reply(answers: [record(rdata: [8, 8, 8, 8])])
        bytes[25] = 28  // question type AAAA
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == nil)
    }

    @Test func questionNameIsCaseInsensitive() {
        let bytes = reply(name: "DNS.Google", answers: [record(rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .answered(["8.8.8.8"]))
    }

    @Test func truncatedAnswerFails() {
        let bytes = reply(answers: [record(rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(Array(bytes.dropLast(2)), id: 0x1234, name: "dns.google") == .failed)
        #expect(parseDNSResponse(Array(bytes.prefix(8)), id: 0x1234, name: "dns.google") == .failed)
    }

    @Test(.timeLimit(.minutes(1)))
    func selfPointingNameFails() {
        // The answer starts at offset 28 and its name points at itself.
        let bytes = reply(answers: [record(name: [0xC0, 28], rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .failed)
    }
    @Test func truncatedFlagFails() {
        var bytes = reply(answers: [record(rdata: [8, 8, 8, 8])])
        bytes[2] |= 0x02  // TC
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .failed)
        var negative = reply(rcode: 3)
        negative[2] |= 0x02
        #expect(parseDNSResponse(negative, id: 0x1234, name: "dns.google") == .failed)
    }

    @Test func reservedLabelTypesFail() {
        for first: UInt8 in [0x40, 0x80] {
            let bytes = reply(answers: [record(name: [first | 0x01, 0x00], rdata: [8, 8, 8, 8])])
            #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .failed, "\(first)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func twoPointerLoopFails() {
        // The answer's name starts at offset 28: a pointer to 30, where a pointer leads back to 28.
        let bytes = reply(answers: [record(name: [0xC0, 30, 0xC0, 28], rdata: [8, 8, 8, 8])])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .failed)
    }

    @Test func rdlengthPastTheEndFails() {
        // A complete record header whose rdlength (10) runs past the 4 bytes that follow.
        let header: [UInt8] = [0xC0, 0x0C, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x01, 0x2C, 0x00, 0x0A]
        let bytes = reply(answers: [header + [8, 8, 8, 8]])
        #expect(parseDNSResponse(bytes, id: 0x1234, name: "dns.google") == .failed)
    }
}
