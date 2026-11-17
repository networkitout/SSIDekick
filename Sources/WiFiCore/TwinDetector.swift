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
            /// "1 other named X uses" / "N others named X use".
            func othersUse(_ count: Int) -> String {
                count == 1 ? "1 other named \(ssid) uses" : "\(count) others named \(ssid) use"
            }

            if let (mode, count) = Self.strongerSecurity(own: own, siblings: siblings) {
                add(.securityMismatch, "\(Self.name(own.weakestSecurity)), while \(othersUse(count)) \(Self.name(mode))")
            }

            // Vendor: nobody else has this vendor, yet at least two siblings agree on one. Names are compared by
            // `vendorKey`, so spelling variants of one maker count as the same vendor; reasons print the names.
            if let vendor = vendors.vendor(for: address) {
                let siblingVendors = siblings.compactMap { vendors.vendor(for: $0.bssid!) }
                let ownKey = vendorKey(vendor)
                let byKey = Dictionary(grouping: siblingVendors, by: vendorKey)
                if byKey[ownKey] == nil,
                   let shared = byKey.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
                   shared.value.count >= 2 {
                    let sharedName = shared.value.min()!
                    add(.vendorMismatch, "Made by \(vendor), while \(shared.value.count) others named \(ssid) are made by \(sharedName)")
                }
            }

            if address.isLocallyAdministered, !siblings.contains(where: { $0.bssid!.isLocallyAdministered }) {
                add(.locallyAdministered, "Software-assigned address, while \(othersUse(siblings.count)) hardware addresses")
            }

            // Weak signals need at least two siblings that all agree.
            if siblings.count >= 2 {
                if let agreed = Self.unanimous(siblings.map(\.countryCode)), agreed != own.countryCode {
                    let mine = own.countryCode.map { "Country \($0)" } ?? "No country set"
                    add(.countryMismatch, "\(mine), while \(othersUse(siblings.count)) \(agreed)")
                }
                if let agreed = Self.unanimous(siblings.map { Optional($0.beaconInterval) }), agreed != own.beaconInterval {
                    add(.beaconMismatch, "Beacon interval \(own.beaconInterval) ms, while \(othersUse(siblings.count)) \(agreed) ms")
                }
                if let agreed = Self.unanimous(siblings.map(\.generation)), agreed != own.generation {
                    let mine = own.generation.map { "Wi-Fi \($0.rawValue)" } ?? "No Wi-Fi generation reported"
                    add(.generationMismatch, "\(mine), while \(othersUse(siblings.count)) Wi-Fi \(agreed.rawValue)")
                }
            }
        }
        return out
    }

    /// The security an access point falls short of, with how many siblings use it, or nil when it does not.
    ///
    /// Siblings compared: for a 2.4 or 5 GHz access point every sibling except 6 GHz ones (6 GHz requires WPA3, so a
    /// tri-band router's lower radios would otherwise look weak); a 6 GHz access point compares against all.
    /// - Open or WEP beside any sibling on WPA or better: always a mismatch.
    /// - A weaker WPA generation: a mismatch only when the stronger siblings are a strict majority of the
    ///   comparison group, the access point itself included, so a two-radio router split WPA2/WPA3 stays silent.
    /// The mode named is the most common among the stronger siblings (ties go to the higher mode).
    private static func strongerSecurity(own: AccessPoint, siblings: [AccessPoint]) -> (SecurityMode, Int)? {
        let compared = own.channel.band == .ghz6 ? siblings : siblings.filter { $0.channel.band != .ghz6 }
        let mine = own.weakestSecurity
        let stronger = compared.map(\.weakestSecurity).filter { $0 > mine && $0 >= .wpa }
        guard !stronger.isEmpty else { return nil }
        if mine >= .wpa, stronger.count * 2 <= compared.count + 1 { return nil }
        let counts = Dictionary(grouping: stronger, by: { $0 }).mapValues(\.count)
        let common = counts.max { ($0.value, $0.key) < ($1.value, $1.key) }!
        return (common.key, common.value)
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
