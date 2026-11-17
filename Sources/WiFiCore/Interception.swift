import Foundation

public enum DNSLookup: Sendable, Equatable {
    case answered([String])
    case nameError
    case refused
    case failed
}

public enum DNSAnswersState: Sendable, Hashable {
    case notChecked, off, noAnswer
    case asExpected
    case filtered
    case filteredByYourServer(name: String, address: String)
    case rewritten(address: String)
    case tampered(name: String, address: String, expected: [String])
}

public enum HTTPSState: Sendable, Hashable {
    case notChecked, off, noAnswer
    case direct
    case decryptable(root: String)
    case rejected
}

public enum InterceptionCheck {
    public static let knownNames: [(name: String, expected: [String])] =
        [("one.one.one.one", ["1.1.1.1", "1.0.0.1"]), ("dns.google", ["8.8.8.8", "8.8.4.4"])]
    public static let interval: TimeInterval = 300
    public static let httpsURL = "https://www.apple.com/"
}

public func madeUpName() -> String {
    let letters = Array("abcdefghijklmnopqrstuvwxyz")
    return String((0..<12).map { _ in letters.randomElement()! }) + ".example.com"
}

/// Parses a dotted IPv4 address (via inet_pton) into its four bytes.
private func ipv4Bytes(_ ip: String) -> [UInt8]? {
    var addr = in_addr()
    guard inet_pton(AF_INET, ip, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: &addr) { Array($0) }
}

/// Parses an IPv6 address (via inet_pton) into its sixteen bytes; a "%scope" suffix is ignored.
private func ipv6Bytes(_ ip: String) -> [UInt8]? {
    let bare = ip.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        .first.map(String.init) ?? ip
    var addr = in6_addr()
    guard inet_pton(AF_INET6, bare, &addr) == 1 else { return nil }
    return withUnsafeBytes(of: &addr) { Array($0) }
}

public func isPrivateAddress(_ ip: String) -> Bool {
    if let b = ipv4Bytes(ip) {
        switch (b[0], b[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
    if let b = ipv6Bytes(ip) {
        if b.dropLast().allSatisfy({ $0 == 0 }) && b[15] == 1 { return true }   // ::1
        if b[0] & 0xFE == 0xFC { return true }                                   // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return true }                   // fe80::/10
    }
    return false
}

/// IPv4 prefixes that DNS filters answer with. 146.112.61.0/24 is Cisco Umbrella's
/// block-page range, as published in Cisco Umbrella's public documentation of its
/// block-page addresses. 0.0.0.0 and 127/8 are the null/loopback answers filters return.
private let blockPrefixes: [(bytes: [UInt8], bits: Int)] = [
    ([0, 0, 0, 0], 32),
    ([127, 0, 0, 0], 8),
    ([146, 112, 61, 0], 24),
]

public func isBlockAnswer(_ ip: String) -> Bool {
    guard let b = ipv4Bytes(ip) else { return false }
    return blockPrefixes.contains { prefix in
        var remaining = prefix.bits
        for i in 0..<4 where remaining > 0 {
            let n = min(8, remaining)
            let mask = UInt8(truncatingIfNeeded: 0xFF << (8 - n))
            if b[i] & mask != prefix.bytes[i] & mask { return false }
            remaining -= n
        }
        return true
    }
}

private func rank(_ s: DNSAnswersState) -> Int {
    switch s {
    case .tampered: 4
    case .rewritten: 3
    case .filteredByYourServer: 2
    case .filtered: 1
    default: 0
    }
}

public func classifyDNS(known: [(name: String, lookup: DNSLookup)], madeUp: DNSLookup,
                        handSetPrivateServer: Bool) -> DNSAnswersState {
    var results: [DNSAnswersState] = []

    for (name, lookup) in known {
        let expected = InterceptionCheck.knownNames.first { $0.name == name }?.expected ?? []
        switch lookup {
        case .failed: continue
        case .nameError, .refused: results.append(.filtered)
        case .answered(let addrs):
            if addrs.isEmpty { results.append(.filtered); continue }
            let unexpected = addrs.filter { !expected.contains($0) }
            if unexpected.isEmpty { results.append(.asExpected); continue }
            if let bad = unexpected.first(where: { !isBlockAnswer($0) }) {
                results.append(handSetPrivateServer
                    ? .filteredByYourServer(name: name, address: bad)
                    : .tampered(name: name, address: bad, expected: expected))
            } else {
                results.append(.filtered)
            }
        }
    }

    switch madeUp {
    case .answered(let addrs):
        if let first = addrs.first { results.append(.rewritten(address: first)) }
        else { results.append(.asExpected) }
    case .nameError: results.append(.asExpected)
    case .refused, .failed: break
    }

    guard !results.isEmpty else { return .noAnswer }
    var worst = results[0]
    for r in results.dropFirst() where rank(r) > rank(worst) { worst = r }
    return worst
}

public func classifyTLS(trustPassed: Bool?, rootIsSystemAnchor: Bool, rootName: String?) -> HTTPSState {
    guard let passed = trustPassed else { return .noAnswer }
    if !passed { return .rejected }
    return rootIsSystemAnchor ? .direct : .decryptable(root: rootName ?? "unknown")
}

public func dnsAnswersText(_ state: DNSAnswersState) -> String {
    switch state {
    case .notChecked: "not checked"
    case .off: "off"
    case .noAnswer: "no answer"
    case .asExpected: "as expected"
    case .filtered: "filtered · public DNS names blocked"
    case .filteredByYourServer(let n, let a): "filtered by your DNS server · \(n) → \(a)"
    case .rewritten(let a): "rewritten · made-up names resolve to \(a)"
    case .tampered(let n, let a, _): "tampered · \(n) → \(a)"
    }
}

public func dnsAnswersLevel(_ state: DNSAnswersState) -> QualityLevel {
    switch state {
    case .notChecked, .off, .noAnswer: .unknown
    case .asExpected: .good
    case .filtered, .filteredByYourServer, .rewritten: .fair
    case .tampered: .poor
    }
}

public func httpsText(_ state: HTTPSState) -> String {
    switch state {
    case .notChecked: "not checked"
    case .off: "off"
    case .noAnswer: "no answer"
    case .direct: "direct · Apple-trusted root"
    case .decryptable(let r): "can be decrypted · root \"\(r)\""
    case .rejected: "certificate rejected"
    }
}

public func httpsLevel(_ state: HTTPSState) -> QualityLevel {
    switch state {
    case .notChecked, .off, .noAnswer: .unknown
    case .direct: .good
    case .decryptable: .fair
    case .rejected: .poor
    }
}
