import Foundation

public protocol VendorLookup: Sendable {
    func vendor(for address: MACAddress) -> String?
}

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

    public func vendor(for address: MACAddress) -> String? {
        guard !address.isLocallyAdministered else { return nil }
        return names[address.oui]
    }
}
