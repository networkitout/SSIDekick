import WiFiCore

func ap(_ ssid: String?, _ bssid: String?, rssi: Int = -60, ch: Int = 44, band: Band = .ghz5, width: Int = 80,
        sec: Set<SecurityMode> = [.wpa2], gen: WiFiGeneration? = .wifi6, cc: String? = "US",
        beacon: Int = 100) -> AccessPoint {
    AccessPoint(ssid: ssid, bssid: bssid.flatMap { MACAddress($0) }, rssi: rssi, noise: -90,
                channel: Channel(number: ch, band: band, widthMHz: width),
                security: sec, generation: gen, countryCode: cc, beaconInterval: beacon)
}
