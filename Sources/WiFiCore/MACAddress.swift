import Foundation

public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public let bytes: [UInt8]

    /// Parses six hex groups separated by ":" or "-". Groups may be unpadded (1 or 2 digits).
    public init?(_ string: String) {
        let parts = string.split(separator: /[:\-]/, omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }
        var parsed: [UInt8] = []
        parsed.reserveCapacity(6)
        for part in parts {
            guard (1...2).contains(part.count), let byte = UInt8(part, radix: 16) else { return nil }
            parsed.append(byte)
        }
        self.bytes = parsed
    }

    public var oui: UInt32 {
        (UInt32(bytes[0]) << 16) | (UInt32(bytes[1]) << 8) | UInt32(bytes[2])
    }

    public var isLocallyAdministered: Bool { bytes[0] & 0x02 != 0 }

    public var description: String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
