import Foundation

public enum Band: Sendable, Hashable, Comparable { case ghz2_4, ghz5, ghz6 }

public struct Channel: Sendable, Hashable {
    public var number: Int
    public var band: Band
    public var widthMHz: Int

    public init(number: Int, band: Band, widthMHz: Int) {
        self.number = number
        self.band = band
        self.widthMHz = widthMHz
    }
}

public enum SecurityMode: Int, Sendable, Hashable, Comparable, CaseIterable {
    case open = 0, wep, wpa, wpa2, wpa3

    public static func < (lhs: SecurityMode, rhs: SecurityMode) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum WiFiGeneration: Int, Sendable, Hashable, Comparable {
    case wifi1 = 1, wifi2, wifi3, wifi4, wifi5, wifi6, wifi7

    public static func < (lhs: WiFiGeneration, rhs: WiFiGeneration) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct AccessPoint: Sendable, Hashable {
    public var ssid: String?
    public var bssid: MACAddress?
    public var rssi: Int
    public var noise: Int
    public var channel: Channel
    /// Every mode the access point accepts.
    public var security: Set<SecurityMode>
    public var generation: WiFiGeneration?
    public var countryCode: String?
    public var beaconInterval: Int

    /// Minimum of `security`; `.open` when the set is empty.
    public var weakestSecurity: SecurityMode { security.min() ?? .open }

    public init(ssid: String?, bssid: MACAddress?, rssi: Int, noise: Int, channel: Channel,
                security: Set<SecurityMode>, generation: WiFiGeneration?, countryCode: String?,
                beaconInterval: Int) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.security = security
        self.generation = generation
        self.countryCode = countryCode
        self.beaconInterval = beaconInterval
    }
}

public struct LinkSnapshot: Sendable, Hashable {
    public var ssid: String?
    public var bssid: MACAddress?
    public var rssi: Int
    public var noise: Int
    public var txRateMbps: Double
    public var channel: Channel
    public var generation: WiFiGeneration?
    public var security: SecurityMode?
    public var countryCode: String?

    /// Signal-to-noise ratio in dB: rssi - noise.
    public var snr: Int { rssi - noise }

    public init(ssid: String?, bssid: MACAddress?, rssi: Int, noise: Int, txRateMbps: Double,
                channel: Channel, generation: WiFiGeneration?, security: SecurityMode?,
                countryCode: String?) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
        self.noise = noise
        self.txRateMbps = txRateMbps
        self.channel = channel
        self.generation = generation
        self.security = security
        self.countryCode = countryCode
    }
}
