import Foundation

public protocol VendorLookup: Sendable {
    func vendor(for address: MACAddress) -> String?
    /// True when no vendor is known at all, so vendor checks cannot run.
    var isEmpty: Bool { get }
}

public extension VendorLookup {
    var isEmpty: Bool { false }
}

/// Shown in the scan window and the report while the vendor table is empty.
public let vendorTableMissingText = "Vendor table not installed — vendor checks are off."

/// OUI-to-vendor lookup. Input is one "A4B1C2<TAB>Vendor name" per line; blank and malformed lines are skipped.
public struct VendorTable: VendorLookup {
    private let names: [UInt32: String]

    public init(tsv: String) {
        var names: [UInt32: String] = [:]
        for line in tsv.split(whereSeparator: \.isNewline) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let key = line[..<tab]
            let name = line[line.index(after: tab)...].trimmingCharacters(in: .whitespaces)
            guard key.count == 6, let oui = UInt32(key, radix: 16), !name.isEmpty else { continue }
            names[oui] = name
        }
        self.names = names
    }

    public static let empty = VendorTable(tsv: "")

    public var isEmpty: Bool { names.isEmpty }

    public func vendor(for address: MACAddress) -> String? {
        guard !address.isLocallyAdministered else { return nil }
        return names[address.oui]
    }
}

private let vendorStoplist: Set<String> = [
    "the", "shenzhen", "hangzhou", "beijing", "shanghai", "guangdong", "guangzhou", "zhejiang", "nanjing",
    "sichuan", "chengdu", "taiwan", "hon", "hai",
]

/// A comparison key for a vendor name, so spelling variants of one maker match ("Cisco Systems, Inc" and
/// "Cisco Meraki" both give "cisco"): lowercased, punctuation removed, leading place and filler words dropped,
/// first remaining word. When every word is a stop word, the whole normalised name.
public func vendorKey(_ name: String) -> String {
    let stripped = String(String.UnicodeScalarView(
        name.lowercased().unicodeScalars.filter { !CharacterSet.punctuationCharacters.contains($0) }))
    let tokens = stripped.split(whereSeparator: \.isWhitespace).map(String.init)
    if let first = tokens.drop(while: { vendorStoplist.contains($0) }).first { return first }
    return tokens.joined(separator: " ")
}
