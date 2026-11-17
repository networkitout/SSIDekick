import Darwin
import Foundation
import WiFiCore

/// A DNS query for the A record of `name`, recursion desired.
func dnsQuery(name: String, id: UInt16) -> [UInt8] {
    var query: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF),
                          0x01, 0x00,  // flags: recursion desired
                          0x00, 0x01,  // one question
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    for label in name.split(separator: ".") {
        let bytes = Array(label.utf8)
        query.append(UInt8(bytes.count))
        query += bytes
    }
    query += [0x00, 0x00, 0x01, 0x00, 0x01]  // root, type A, class IN
    return query
}

/// A numeric DNS server address and port. IPv6 link-local addresses may carry a scope ("fe80::1%en0").
struct DNSServerAddress {
    var storage: sockaddr_storage
    var length: socklen_t

    var family: Int32 { Int32(storage.ss_family) }

    var scopeID: UInt32 {
        guard family == AF_INET6 else { return 0 }
        return withUnsafePointer(to: storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_scope_id }
        }
    }
}

/// Parses a numeric IPv4 or IPv6 server address without any name lookup; nil for anything else.
func dnsServerAddress(_ text: String, port: UInt16 = 53) -> DNSServerAddress? {
    guard !text.isEmpty else { return nil }
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(text, String(port), &hints, &result) == 0, let info = result else { return nil }
    defer { freeaddrinfo(result) }
    guard let address = info.pointee.ai_addr,
          info.pointee.ai_addrlen <= socklen_t(MemoryLayout<sockaddr_storage>.size) else { return nil }
    var storage = sockaddr_storage()
    withUnsafeMutableBytes(of: &storage) { destination in
        destination.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(info.pointee.ai_addrlen)))
    }
    return DNSServerAddress(storage: storage, length: info.pointee.ai_addrlen)
}

/// Sends one query for apple.com to `server` over UDP on `interface` and returns the time to a response with the
/// same id.
func dnsProbe(server: String, interface: String, timeout: TimeInterval) async -> PingResult {
    guard let address = dnsServerAddress(server) else { return .blocked }
    let id = UInt16.random(in: 0...UInt16.max)
    let query = dnsQuery(name: "apple.com", id: id)
    let outcome = await dnsExchange(query, server: address, interface: interface, timeout: timeout) { reply in
        reply.count >= 2 && UInt16(reply[0]) << 8 | UInt16(reply[1]) == id ? () : nil
    }
    switch outcome {
    case .notSent: return .blocked
    case .noReply: return .timeout
    case .reply(_, let milliseconds): return .reply(milliseconds)
    }
}

/// Looks up the A records of `name` on `server` over UDP on `interface`. `.failed` when the query cannot be sent or
/// no reply for it arrives in time; datagrams that are not a reply to this query are ignored.
func dnsLookup(name: String, server: String, port: UInt16 = 53, interface: String,
               timeout: TimeInterval) async -> DNSLookup {
    guard let address = dnsServerAddress(server, port: port) else { return .failed }
    let id = UInt16.random(in: 0...UInt16.max)
    let query = dnsQuery(name: name, id: id)
    let outcome = await dnsExchange(query, server: address, interface: interface, timeout: timeout) { reply in
        parseDNSResponse(reply, id: id, name: name)
    }
    switch outcome {
    case .notSent, .noReply: return .failed
    case .reply(let lookup, _): return lookup
    }
}

private enum DNSExchangeOutcome<Reply> {
    /// The query could not be sent at all.
    case notSent
    /// Sent, but no accepted reply in time.
    case noReply
    /// The first reply `accept` took, and the milliseconds from sending to receiving it.
    case reply(Reply, milliseconds: Double)
}

/// Sends `query` from a UDP socket bound to `interface` and connected to `server`, then waits until `accept` takes a
/// reply (non-nil) or the timeout passes. The socket work runs off the calling thread.
private func dnsExchange<Reply>(_ query: [UInt8], server: DNSServerAddress, interface: String,
                                timeout: TimeInterval,
                                accept: @escaping ([UInt8]) -> Reply?) async -> DNSExchangeOutcome<Reply> {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: blockingDNSExchange(query, server: server, interface: interface,
                                                               timeout: timeout, accept: accept))
        }
    }
}

private func blockingDNSExchange<Reply>(_ query: [UInt8], server: DNSServerAddress, interface: String,
                                        timeout: TimeInterval,
                                        accept: ([UInt8]) -> Reply?) -> DNSExchangeOutcome<Reply> {
    // Every failure to send is `.notSent`; only a missing answer is `.noReply`.
    let fd = socket(server.family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return .notSent }
    defer { close(fd) }
    guard bind(fd, family: server.family, toInterface: interface) else { return .notSent }

    // Connecting the socket means only datagrams from the server are delivered.
    var storage = server.storage
    let connected = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, server.length) }
    }
    guard connected == 0 else { return .notSent }

    let start = monotonicNanos()
    let deadline = start + UInt64(max(0, timeout) * 1_000_000_000)
    let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == query.count else { return .notSent }

    var buffer = [UInt8](repeating: 0, count: 512)
    while waitReadable(fd, deadline: deadline) {
        let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard received > 0 else { return .noReply }
        if let reply = accept(Array(buffer.prefix(received))) {
            return .reply(reply, milliseconds: Double(monotonicNanos() - start) / 1_000_000)
        }
    }
    return .noReply
}
