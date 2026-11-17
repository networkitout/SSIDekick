import Foundation
import WiFiCore

/// Reads a reply to `dnsQuery(name: name, id: id)`.
///
/// nil when the datagram is not a reply to this query (a different id, the QR bit clear, or another question name or
/// type), so the caller keeps waiting. `.failed` for a truncated or malformed reply and for any rcode other than
/// 0 (answers), 3 (`.nameError`) and 5 (`.refused`). With rcode 0, the A addresses of every answer record, in order;
/// CNAMEs and other types are skipped.
func parseDNSResponse(_ bytes: [UInt8], id: UInt16, name: String) -> DNSLookup? {
    guard bytes.count >= 2 else { return nil }
    guard UInt16(bytes[0]) << 8 | UInt16(bytes[1]) == id else { return nil }
    guard bytes.count >= 12 else { return .failed }
    guard bytes[2] & 0x80 != 0 else { return nil }

    let rcode = bytes[3] & 0x0F
    let questions = Int(bytes[4]) << 8 | Int(bytes[5])
    let answers = Int(bytes[6]) << 8 | Int(bytes[7])
    guard questions == 1 else { return nil }

    var reader = DNSReader(bytes: bytes, offset: 12)
    guard let questionName = reader.readName(), let questionType = reader.readUInt16(),
          reader.readUInt16() != nil else { return .failed }
    guard questionType == 1, sameName(questionName, name) else { return nil }

    switch rcode {
    case 0: break
    case 3: return .nameError
    case 5: return .refused
    default: return .failed
    }

    var addresses: [String] = []
    for _ in 0..<answers {
        guard reader.readName() != nil,
              let type = reader.readUInt16(), let recordClass = reader.readUInt16(),
              reader.skip(4),  // TTL
              let length = reader.readUInt16(),
              let data = reader.read(Int(length)) else { return .failed }
        if type == 1, recordClass == 1, data.count == 4 {
            addresses.append(data.map(String.init).joined(separator: "."))
        }
    }
    return .answered(addresses)
}

/// Compares a name read from the wire with a dotted name, ignoring ASCII case and a trailing dot.
private func sameName(_ labels: [[UInt8]], _ name: String) -> Bool {
    let wanted = name.split(separator: ".").map { Array($0.utf8) }
    guard wanted.count == labels.count else { return false }
    return zip(labels, wanted).allSatisfy { lhs, rhs in
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { asciiLower($0) == asciiLower($1) }
    }
}

private func asciiLower(_ byte: UInt8) -> UInt8 {
    (0x41...0x5A).contains(byte) ? byte | 0x20 : byte
}

/// A bounds-checked cursor over a DNS message. Every read returns nil (or false) past the end.
private struct DNSReader {
    let bytes: [UInt8]
    var offset: Int

    mutating func read(_ count: Int) -> ArraySlice<UInt8>? {
        guard count >= 0, offset + count <= bytes.count else { return nil }
        defer { offset += count }
        return bytes[offset..<offset + count]
    }

    mutating func skip(_ count: Int) -> Bool { read(count) != nil }

    mutating func readUInt16() -> UInt16? {
        guard let pair = read(2) else { return nil }
        return UInt16(pair[pair.startIndex]) << 8 | UInt16(pair[pair.startIndex + 1])
    }

    /// Reads a name, following compression pointers, and leaves the cursor just past it.
    /// nil when it runs off the end, uses a reserved label type, is longer than 255 bytes or its pointers loop.
    mutating func readName() -> [[UInt8]]? {
        var labels: [[UInt8]] = []
        var position = offset
        var resume: Int?
        var jumps = 0
        var length = 0
        while true {
            guard position < bytes.count else { return nil }
            let byte = bytes[position]
            switch byte & 0xC0 {
            case 0xC0:
                guard position + 1 < bytes.count else { return nil }
                // A pointer takes two bytes, so a chain longer than half the message revisits one: a loop.
                jumps += 1
                guard jumps <= bytes.count / 2 else { return nil }
                if resume == nil { resume = position + 2 }
                position = Int(byte & 0x3F) << 8 | Int(bytes[position + 1])
            case 0x00:
                let count = Int(byte)
                length += count + 1
                guard length <= 255 else { return nil }
                if count == 0 {
                    offset = resume ?? position + 1
                    return labels
                }
                guard position + 1 + count <= bytes.count else { return nil }
                labels.append(Array(bytes[position + 1...position + count]))
                position += 1 + count
            default:
                return nil
            }
        }
    }
}
