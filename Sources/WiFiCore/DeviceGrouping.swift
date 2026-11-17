import Foundation

/// Radios that probably belong to one physical device: same maker prefix and neighbouring addresses.
/// Display only: a radio with a finding is never folded into a device.
public struct DeviceGroup: Sendable, Identifiable {
    /// The lowest address in the device ("none-<n>" for a radio without an address).
    public var id: String
    /// Strongest first.
    public var accessPoints: [AccessPoint]
    /// The lowest address with its last two hex digits as "x" when the device has several radios.
    public var addressPattern: String
    /// Distinct, ascending.
    public var bands: [Band]
    public var strongestRSSI: Int
    public var isSingleRadio: Bool { accessPoints.count == 1 }

    public init(id: String, accessPoints: [AccessPoint], addressPattern: String, bands: [Band], strongestRSSI: Int) {
        self.id = id
        self.accessPoints = accessPoints
        self.addressPattern = addressPattern
        self.bands = bands
        self.strongestRSSI = strongestRSSI
    }
}

/// Radios closer than this many addresses (last byte) to a device's lowest radio join that device.
private let deviceAddressSpan = 15

/// Folds one network's access points into devices. Radios with no address, or with a finding, stay alone.
/// Order: the device with the strongest radio first, then by strongest signal, then by id.
/// Every returned `id` is unique within one call, for any input.
public func groupDevices(_ accessPoints: [AccessPoint], findings: [Finding]) -> [DeviceGroup] {
    var devices: [DeviceGroup] = []
    var keyed: [[UInt8]: [(AccessPoint, MACAddress)]] = [:]
    for (index, accessPoint) in accessPoints.enumerated() {
        guard let bssid = accessPoint.bssid, bssid.bytes.count == 6,
              WiFiCore.findings(for: accessPoint, in: findings).isEmpty else {
            let id = accessPoint.bssid?.description ?? "none-\(index)"
            devices.append(makeDevice(id: id, [accessPoint]))
            continue
        }
        let key = [bssid.bytes[0] & ~0x02] + Array(bssid.bytes[1...4])
        keyed[key, default: []].append((accessPoint, bssid))
    }
    for members in keyed.values {
        let sorted = members.sorted { $0.1.isLower(than: $1.1) }
        var current: [(AccessPoint, MACAddress)] = []
        for member in sorted {
            if let lowest = current.first, Int(member.1.bytes[5]) - Int(lowest.1.bytes[5]) > deviceAddressSpan {
                devices.append(makeDevice(id: lowest.1.description, current.map(\.0)))
                current = []
            }
            current.append(member)
        }
        if let lowest = current.first { devices.append(makeDevice(id: lowest.1.description, current.map(\.0))) }
    }
    let ordered = devices.sorted { a, b in
        if a.strongestRSSI != b.strongestRSSI { return a.strongestRSSI > b.strongestRSSI }
        if a.id != b.id { return a.id < b.id }
        return a.accessPoints[0].channel.number < b.accessPoints[0].channel.number
    }
    return uniqueIDs(ordered)
}

/// Makes every id distinct: the address, else "<address>@<channel>", else "<address>@<channel>#<n>".
/// Deterministic for the same input, so two entries for one address (a cloned address on two channels, say) never
/// share an id.
private func uniqueIDs(_ devices: [DeviceGroup]) -> [DeviceGroup] {
    var used: Set<String> = []
    return devices.map { device in
        var device = device
        let base = device.id
        var candidate = base
        if used.contains(candidate) { candidate = "\(base)@\(device.accessPoints[0].channel.number)" }
        var n = 2
        let withChannel = candidate
        while used.contains(candidate) { candidate = "\(withChannel)#\(n)"; n += 1 }
        used.insert(candidate)
        device.id = candidate
        return device
    }
}

private func makeDevice(id: String, _ radios: [AccessPoint]) -> DeviceGroup {
    let byStrength = radios.sorted { $0.rssi > $1.rssi }
    let lowest = radios.compactMap(\.bssid).min { $0.isLower(than: $1) }
    let pattern: String
    if let lowest {
        pattern = radios.count > 1 ? String(lowest.description.dropLast(2)) + "x" : lowest.description
    } else {
        pattern = "–"
    }
    return DeviceGroup(id: id, accessPoints: byStrength, addressPattern: pattern,
                       bands: Set(radios.map(\.channel.band)).sorted(),
                       strongestRSSI: byStrength[0].rssi)
}

/// "6 radios on 2 devices", "1 radio on 1 device".
public func devicesSummary(_ devices: [DeviceGroup]) -> String {
    let radios = devices.reduce(0) { $0 + $1.accessPoints.count }
    return "\(radios) \(radios == 1 ? "radio" : "radios") on \(devices.count) \(devices.count == 1 ? "device" : "devices")"
}

private extension MACAddress {
    /// Orders by last byte, then by the whole address (so siblings with a different first byte still tie-break).
    func isLower(than other: MACAddress) -> Bool {
        bytes[5] != other.bytes[5] ? bytes[5] < other.bytes[5] : bytes.lexicographicallyPrecedes(other.bytes)
    }
}
