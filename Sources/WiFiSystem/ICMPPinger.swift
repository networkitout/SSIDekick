import Darwin
import Foundation

/// Parses a dotted-quad IPv4 literal; nil for anything else (names, IPv6, trailing text).
func ipv4Address(_ text: String) -> in_addr? {
    var address = in_addr()
    return inet_pton(AF_INET, text, &address) == 1 ? address : nil
}

/// RFC 1071 internet checksum over big-endian 16-bit words.
func icmpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    var index = 0
    while index + 1 < bytes.count {
        sum += UInt32(bytes[index]) << 8 | UInt32(bytes[index + 1])
        index += 2
    }
    if index < bytes.count { sum += UInt32(bytes[index]) << 8 }
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

/// Sends one ICMP echo request to an IPv4 address over `interface` and returns the round trip.
/// The socket work runs off the calling thread.
func icmpPing(_ ip: String, interface: String, timeout: TimeInterval) async -> PingResult {
    guard let address = ipv4Address(ip) else { return .blocked }
    return await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            continuation.resume(returning: blockingPing(address, interface: interface, timeout: timeout))
        }
    }
}

/// Binds a socket to one interface (`IP_BOUND_IF` / `IPV6_BOUND_IF`), so its traffic never leaves another way.
/// False when the name is not a plain interface name, the interface does not exist, or the option fails.
func bind(_ fd: Int32, family: Int32, toInterface interface: String) -> Bool {
    guard isValidInterfaceName(interface) else { return false }
    var index = if_nametoindex(interface)
    guard index != 0 else { return false }
    let (level, option) = family == AF_INET6 ? (IPPROTO_IPV6, IPV6_BOUND_IF) : (IPPROTO_IP, IP_BOUND_IF)
    return setsockopt(fd, level, option, &index, socklen_t(MemoryLayout<UInt32>.size)) == 0
}

/// Monotonic clock in nanoseconds.
func monotonicNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Waits until `fd` is readable or the deadline passes. Returns false on timeout or error.
func waitReadable(_ fd: Int32, deadline: UInt64) -> Bool {
    while true {
        let now = monotonicNanos()
        guard now < deadline else { return false }
        let remainingMs = Int32(min((deadline - now + 999_999) / 1_000_000, UInt64(Int32.max)))
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, remainingMs)
        if ready > 0 { return descriptor.revents & Int16(POLLIN) != 0 }
        if ready == 0 { return false }
        if errno != EINTR { return false }
    }
}

private func blockingPing(_ address: in_addr, interface: String, timeout: TimeInterval) -> PingResult {
    // Every failure to send is `.blocked`, never loss: it says nothing about the network.
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else { return .blocked }
    defer { close(fd) }
    guard bind(fd, family: AF_INET, toInterface: interface) else { return .blocked }

    let identifier = UInt16.random(in: 0...UInt16.max)
    let sequence = UInt16.random(in: 0...UInt16.max)
    var packet: [UInt8] = [8, 0, 0, 0,
                           UInt8(identifier >> 8), UInt8(identifier & 0xFF),
                           UInt8(sequence >> 8), UInt8(sequence & 0xFF)]
    packet += (0..<16).map { UInt8($0) }
    let checksum = icmpChecksum(packet)
    packet[2] = UInt8(checksum >> 8)
    packet[3] = UInt8(checksum & 0xFF)

    var destination = sockaddr_in()
    destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    destination.sin_family = sa_family_t(AF_INET)
    destination.sin_addr = address

    let start = monotonicNanos()
    let deadline = start + UInt64(max(0, timeout) * 1_000_000_000)
    let sent = packet.withUnsafeBytes { bytes in
        withUnsafePointer(to: &destination) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
    guard sent == packet.count else { return .blocked }

    var buffer = [UInt8](repeating: 0, count: 256)
    while waitReadable(fd, deadline: deadline) {
        let received = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        guard received > 0 else { return .timeout }
        if isEchoReply(Array(buffer[0..<received]), sequence: sequence) {
            return .reply(Double(monotonicNanos() - start) / 1_000_000)
        }
    }
    return .timeout
}

/// True for an echo reply (type 0) carrying `sequence`. Skips a leading IPv4 header when present.
private func isEchoReply(_ reply: [UInt8], sequence: UInt16) -> Bool {
    guard let first = reply.first else { return false }
    let offset = first >> 4 == 4 ? Int(first & 0x0F) * 4 : 0
    guard reply.count >= offset + 8 else { return false }
    let replySequence = UInt16(reply[offset + 6]) << 8 | UInt16(reply[offset + 7])
    return reply[offset] == 0 && replySequence == sequence
}
