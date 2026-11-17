import CoreWLAN
import Foundation
import WiFiCore

// MARK: - Pure mappings (raw values from CoreWLANTypes.h)

/// Maps a `CWChannelBand` raw value to a band. When the band is unknown (0) or unlisted, the channel number decides:
/// 1...14 is 2.4 GHz, 32...177 is 5 GHz, and any other number is used only in 6 GHz.
func band(forChannelNumber n: Int, cwBandRawValue: Int) -> Band {
    switch cwBandRawValue {
    case 1: return .ghz2_4
    case 2: return .ghz5
    case 3: return .ghz6
    default:
        switch n {
        case 1...14: return .ghz2_4
        case 32...177: return .ghz5
        default: return .ghz6
        }
    }
}

/// Maps a `CWPHYMode` raw value to a Wi-Fi generation; none or an unlisted value gives nil.
func generation(fromPHYModeRawValue raw: Int) -> WiFiGeneration? {
    switch raw {
    case 1: return .wifi2   // 11a
    case 2: return .wifi1   // 11b
    case 3: return .wifi3   // 11g
    case 4: return .wifi4   // 11n
    case 5: return .wifi5   // 11ac
    case 6: return .wifi6   // 11ax
    case 7: return .wifi7   // 11be
    default: return nil
    }
}

/// Maps a `CWSecurity` raw value to a security mode, collapsing personal and enterprise variants.
/// None and OWE are open; unknown or unlisted values give nil.
func securityMode(fromSecurityRawValue raw: Int) -> SecurityMode? {
    switch raw {
    case 0, 14, 15: return .open        // None, OWE, OWE transition
    case 1, 6: return .wep              // WEP, dynamic WEP
    case 2, 3, 7, 8: return .wpa        // WPA personal / mixed, WPA enterprise / mixed
    case 4, 5, 9, 10: return .wpa2      // WPA2 personal, personal, WPA2 enterprise, enterprise
    case 11, 12, 13: return .wpa3       // WPA3 personal, enterprise, transition
    default: return nil
    }
}

/// Maps a `CWChannelWidth` raw value to MHz; unknown gives 20.
private func widthMHz(fromChannelWidthRawValue raw: Int) -> Int {
    switch raw {
    case 2: return 40
    case 3: return 80
    case 4: return 160
    default: return 20
    }
}

/// The highest `CWPHYMode` raw value in CoreWLANTypes.h (11be).
private let highestPHYModeRawValue = 7
/// The highest listed `CWSecurity` raw value in CoreWLANTypes.h (OWE transition), excluding Unknown.
private let highestSecurityRawValue = 15

private func channel(from cw: CWChannel) -> Channel {
    Channel(number: cw.channelNumber,
            band: band(forChannelNumber: cw.channelNumber, cwBandRawValue: cw.channelBand.rawValue),
            widthMHz: widthMHz(fromChannelWidthRawValue: cw.channelWidth.rawValue))
}

/// nil and empty names both mean the name is withheld or hidden.
private func networkName(_ ssid: String?) -> String? {
    guard let ssid, !ssid.isEmpty else { return nil }
    return ssid
}

private func address(_ bssid: String?) -> MACAddress? {
    bssid.flatMap(MACAddress.init)
}

private func accessPoint(from network: CWNetwork) -> AccessPoint? {
    guard let cwChannel = network.wlanChannel else { return nil }
    let security = Set((0...highestSecurityRawValue).compactMap { raw -> SecurityMode? in
        guard let mode = CWSecurity(rawValue: raw), network.supportsSecurity(mode) else { return nil }
        return securityMode(fromSecurityRawValue: raw)
    })
    // Raw order is not generation order (11a is newer than 11b), so take the highest generation.
    let highest = (1...highestPHYModeRawValue).compactMap { raw -> WiFiGeneration? in
        guard let mode = CWPHYMode(rawValue: raw), network.supportsPHYMode(mode) else { return nil }
        return generation(fromPHYModeRawValue: raw)
    }.max()
    return AccessPoint(ssid: networkName(network.ssid), bssid: address(network.bssid), rssi: network.rssiValue,
                       noise: network.noiseMeasurement, channel: channel(from: cwChannel), security: security,
                       generation: highest, countryCode: network.countryCode,
                       beaconInterval: network.beaconInterval)
}

// MARK: - Source

private struct WiFiScanError: LocalizedError {
    let errorDescription: String?
}

/// The real Wi-Fi interface, read through CoreWLAN. Read only: it never joins, leaves or reconfigures a network.
public final class CoreWLANSource: NSObject, WiFiSource {
    private let client = CWWiFiClient.shared()
    private let lock = NSLock()
    private var continuation: AsyncStream<WiFiEvent>.Continuation?

    private static let monitoredEvents: [(CWEventType, String)] = [
        (.powerDidChange, "power"), (.ssidDidChange, "network name"), (.bssidDidChange, "access point"),
        (.linkDidChange, "link"),
    ]

    /// Why event monitoring could not be started, if it failed; without it joins and roams trigger no scan.
    public private(set) var monitoringError: String?
    private static let scanQueue = DispatchQueue(label: "local.wifiutil.wifi-scan", qos: .userInitiated)

    public override init() {
        super.init()
        client.delegate = self
        var failures: [String] = []
        for (type, name) in Self.monitoredEvents {
            do {
                try client.startMonitoringEvent(with: type)
            } catch {
                failures.append("\(name) events: \(error.localizedDescription)")
            }
        }
        monitoringError = failures.isEmpty ? nil : failures.joined(separator: "; ")
    }

    deinit {
        // The client's delegate is weak, so it clears itself.
        try? client.stopMonitoringAllEvents()
        lock.withLock { continuation }?.finish()
    }

    /// The Wi-Fi interface's BSD name, such as "en0".
    public var interfaceName: String? { client.interface()?.interfaceName }

    public func state() -> WiFiState {
        guard let interface = client.interface(), interface.powerOn() else { return .off }
        return Self.hasActiveLink(interface) ? .connected : .notConnected
    }

    public func currentLink() -> LinkSnapshot? {
        guard let interface = client.interface(), interface.powerOn(), Self.hasActiveLink(interface),
              let cwChannel = interface.wlanChannel() else { return nil }
        return LinkSnapshot(ssid: networkName(interface.ssid()), bssid: address(interface.bssid()),
                            rssi: interface.rssiValue(), noise: interface.noiseMeasurement(),
                            txRateMbps: interface.transmitRate(), channel: channel(from: cwChannel),
                            generation: generation(fromPHYModeRawValue: interface.activePHYMode().rawValue),
                            security: securityMode(fromSecurityRawValue: interface.security().rawValue),
                            countryCode: interface.countryCode())
    }

    public func cachedScan() -> [AccessPoint] {
        guard let results = client.interface()?.cachedScanResults() else { return [] }
        return results.compactMap(accessPoint(from:))
    }

    /// Runs CoreWLAN's blocking scan on a background queue.
    public func scan() async throws -> [AccessPoint] {
        try await withCheckedThrowingContinuation { continuation in
            // The interface is looked up on the queue because CoreWLAN objects are not Sendable.
            Self.scanQueue.async {
                guard let interface = CWWiFiClient.shared().interface() else {
                    continuation.resume(throwing: WiFiScanError(errorDescription: "No Wi-Fi interface found."))
                    return
                }
                do {
                    let networks = try interface.scanForNetworks(withName: nil, includeHidden: true)
                    continuation.resume(returning: networks.compactMap(accessPoint(from:)))
                } catch {
                    continuation.resume(throwing: WiFiScanError(errorDescription: error.localizedDescription))
                }
            }
        }
    }

    /// One consumer at a time: reading this again finishes the previous stream and returns a new one.
    public var events: AsyncStream<WiFiEvent> {
        let (stream, newContinuation) = AsyncStream<WiFiEvent>.makeStream()
        let previous = lock.withLock {
            let previous = continuation
            continuation = newContinuation
            return previous
        }
        previous?.finish()
        return stream
    }

    /// A link is active when the interface reports a channel and a non-zero transmit rate, even if the name is hidden.
    private static func hasActiveLink(_ interface: CWInterface) -> Bool {
        interface.wlanChannel() != nil && interface.transmitRate() > 0
    }

    /// Called from CoreWLAN's threads; only touches the lock-protected continuation.
    private func emit(_ event: WiFiEvent) {
        lock.withLock { continuation }?.yield(event)
    }
}

extension CoreWLANSource: CWEventDelegate {
    public func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { emit(.powerChanged) }
    public func ssidDidChangeForWiFiInterface(withName interfaceName: String) { emit(.ssidChanged) }
    public func bssidDidChangeForWiFiInterface(withName interfaceName: String) { emit(.bssidChanged) }
    public func linkDidChangeForWiFiInterface(withName interfaceName: String) { emit(.linkChanged) }
    /// CoreWLAN re-registers events itself; local state is re-read in case a change was missed meanwhile.
    public func clientConnectionInterrupted() { emit(.linkChanged) }
}
