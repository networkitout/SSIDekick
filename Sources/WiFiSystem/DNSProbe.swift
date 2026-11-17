import Darwin
import Foundation

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

/// A numeric DNS server address, port 53. IPv6 link-local addresses may carry a scope ("fe80::1%en0").
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
func dnsServerAddress(_ text: String) -> DNSServerAddress? {
    guard !text.isEmpty else { return nil }
    var hints = addrinfo()
    hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(text, "53", &hints, &result) == 0, let info = result else { return nil }
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
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: blockingDNSProbe(address, interface: interface, timeout: timeout))
        }
    }
}

private func blockingDNSProbe(_ server: DNSServerAddress, interface: String, timeout: TimeInterval) -> PingResult {
    // Every failure to send is `.blocked`; only a missing answer is `.timeout`.
    let fd = socket(server.family, SOCK_DGRAM, IPPROTO_UDP)
    guard fd >= 0 else { return .blocked }
    defer { close(fd) }
    guard bind(fd, family: server.family, toInterface: interface) else { return .blocked }

    // Connecting the socket means only datagrams from the server are delivered.
    var storage = server.storage
    let connected = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, server.length) }
    }
    guard connected == 0 else { return .blocked }

    let id = UInt16.random(in: 0...UInt16.max)
    let query = dnsQuery(name: "apple.com", id: id)
    let start = monotonicNanos()
    let deadline = start + UInt64(max(0, timeout) * 1_000_000_000)
    let sent = query.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
    guard sent == query.count else { return .blocked }

    var buffer = [UInt8](repeating: 0, count: 512)
    while waitReadable(fd, deadline: deadline) {
        let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard received > 0 else { return .timeout }
        if received >= 2, UInt16(buffer[0]) << 8 | UInt16(buffer[1]) == id {
            return .reply(Double(monotonicNanos() - start) / 1_000_000)
        }
    }
    return .timeout
}
