import Foundation

/// Compares access points that share a network name and reports the ones that differ from their siblings.
public struct TwinDetector: Sendable {
    private let vendors: VendorLookup

    public init(vendors: VendorLookup) {
        self.vendors = vendors
    }

    public func findings(in scan: [AccessPoint]) -> [Finding] {
        var groups: [String: [AccessPoint]] = [:]
        for entry in scan {
            guard let ssid = entry.ssid, entry.bssid != nil else { continue }
            groups[ssid, default: []].append(entry)
        }
        var result: [Finding] = []
        for (ssid, entries) in groups {
            result += findings(ssid: ssid, entries: entries)
        }
        return result.sorted {
            ($0.ssid, $0.bssid?.description ?? "", $0.signal.rawValue)
                < ($1.ssid, $1.bssid?.description ?? "", $1.signal.rawValue)
        }
    }

    private func findings(ssid: String, entries: [AccessPoint]) -> [Finding] {
        // One representative entry per distinct address, in first-seen order.
        var order: [MACAddress] = []
        var byAddress: [MACAddress: [AccessPoint]] = [:]
        for entry in entries {
            guard let address = entry.bssid else { continue }
            if byAddress[address] == nil { order.append(address) }
            byAddress[address, default: []].append(entry)
        }

        var out: [Finding] = []
        for address in order {
            let own = byAddress[address]![0]
            let siblings = order.filter { $0 != address }.map { byAddress[$0]![0] }

            if Set(byAddress[address]!.map(\.channel.number)).count >= 2 {
                out.append(Finding(signal: .clonedAddress, ssid: ssid, bssid: address,
                                   reason: "The same address \(address) is on more than one channel"))
            }
            guard !siblings.isEmpty else { continue }

            func add(_ signal: Signal, _ reason: String) {
                out.append(Finding(signal: signal, ssid: ssid, bssid: address, reason: reason))
            }
            let others = siblings.count == 1 ? "1 other" : "\(siblings.count) others"

            // Security: weaker than what most siblings use.
            let counts = Dictionary(grouping: siblings, by: \.weakestSecurity).mapValues(\.count)
            if let common = counts.max(by: { ($0.value, $0.key) < ($1.value, $1.key) }),
               own.weakestSecurity < common.key {
                add(.securityMismatch,
                    "\(Self.name(own.weakestSecurity)), while \(common.value) \(common.value == 1 ? "other" : "others") named \(ssid) use \(Self.name(common.key))")
            }

            // Vendor: nobody else has this vendor, yet at least two siblings agree on one.
            if let vendor = vendors.vendor(for: address) {
                let siblingVendors = siblings.compactMap { vendors.vendor(for: $0.bssid!) }
                let vendorCounts = Dictionary(grouping: siblingVendors, by: { $0 }).mapValues(\.count)
                if !siblingVendors.contains(vendor), let shared = vendorCounts.max(by: { $0.value < $1.value }),
                   shared.value >= 2 {
                    add(.vendorMismatch, "Made by \(vendor), while \(shared.value) others named \(ssid) are made by \(shared.key)")
                }
            }

            if address.isLocallyAdministered, !siblings.contains(where: { $0.bssid!.isLocallyAdministered }) {
                add(.locallyAdministered, "Software-assigned address, while \(others) named \(ssid) use hardware addresses")
            }

            // Weak signals need at least two siblings that all agree.
            if siblings.count >= 2 {
                if let agreed = Self.unanimous(siblings.map(\.countryCode)), agreed != own.countryCode {
                    let mine = own.countryCode.map { "Country \($0)" } ?? "No country set"
                    add(.countryMismatch, "\(mine), while \(others) named \(ssid) use \(agreed)")
                }
                if let agreed = Self.unanimous(siblings.map { Optional($0.beaconInterval) }), agreed != own.beaconInterval {
                    add(.beaconMismatch, "Beacon interval \(own.beaconInterval) ms, while \(others) named \(ssid) use \(agreed) ms")
                }
                if let agreed = Self.unanimous(siblings.map(\.generation)), agreed != own.generation {
                    let mine = own.generation.map { "Wi-Fi \($0.rawValue)" } ?? "No Wi-Fi generation reported"
                    add(.generationMismatch, "\(mine), while \(others) named \(ssid) use Wi-Fi \(agreed.rawValue)")
                }
            }
        }
        return out
    }

    /// The single value every element shares, or nil if any is nil or they differ.
    private static func unanimous<T: Hashable>(_ values: [T?]) -> T? {
        guard let first = values.first, let value = first else { return nil }
        return values.allSatisfy { $0 == value } ? value : nil
    }

    private static func name(_ mode: SecurityMode) -> String {
        switch mode {
        case .open: "Open"
        case .wep: "WEP"
        case .wpa: "WPA"
        case .wpa2: "WPA2"
        case .wpa3: "WPA3"
        }
    }
}
