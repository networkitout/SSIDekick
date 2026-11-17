import Foundation

/// How good a measurement is. The app maps levels to colours; WiFiCore never does.
public enum QualityLevel: Int, Sendable, Comparable {
    case unknown, good, fair, poor

    public static func < (lhs: QualityLevel, rhs: QualityLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Signal strength: good down to -60 dBm, fair down to -70 dBm, poor below.
public func signalLevel(rssi: Int) -> QualityLevel {
    rssi >= -60 ? .good : rssi >= -70 ? .fair : .poor
}

/// Signal bars, 1 to 4: -55 and above 4, down to -65 3, down to -75 2, below 1.
public func signalBars(rssi: Int) -> Int {
    rssi >= -55 ? 4 : rssi >= -65 ? 3 : rssi >= -75 ? 2 : 1
}

/// Signal-to-noise ratio: good from 25 dB, fair from 15 dB, poor below.
public func snrLevel(_ snr: Int) -> QualityLevel {
    snr >= 25 ? .good : snr >= 15 ? .fair : .poor
}

/// Gateway round trip: good under 20 ms, fair up to 100 ms, poor above.
public func gatewayLatencyLevel(_ ms: Double?) -> QualityLevel {
    guard let ms else { return .unknown }
    return ms < 20 ? .good : ms <= 100 ? .fair : .poor
}

/// Packet loss: good at 0 %, fair up to 5 %, poor above.
public func lossLevel(_ percent: Int?) -> QualityLevel {
    guard let percent else { return .unknown }
    return percent <= 0 ? .good : percent <= 5 ? .fair : .poor
}

/// DNS query time: good under 50 ms, fair up to 200 ms, poor above.
public func dnsLatencyLevel(_ ms: Double?) -> QualityLevel {
    guard let ms else { return .unknown }
    return ms < 50 ? .good : ms <= 200 ? .fair : .poor
}

public func internetLevel(_ status: InternetStatus) -> QualityLevel {
    switch status {
    case .unknown: .unknown
    case .online: .good
    case .captivePortal: .fair
    case .offline: .poor
    }
}

/// The worse of latency and loss; unknown when the probe was blocked or neither is known.
public func gatewayLevel(_ net: ConnectivitySnapshot) -> QualityLevel {
    guard !net.gatewayBlocked else { return .unknown }
    return worseOf(gatewayLatencyLevel(net.gatewayLatencyMs), lossLevel(net.gatewayLossPercent))
}

/// DNS latency level; unknown when the query was blocked.
public func dnsLevel(_ net: ConnectivitySnapshot) -> QualityLevel {
    net.dnsBlocked ? .unknown : dnsLatencyLevel(net.dnsLatencyMs)
}

/// The worse level by good < fair < poor, ignoring unknown unless both are unknown.
private func worseOf(_ a: QualityLevel, _ b: QualityLevel) -> QualityLevel {
    if a == .unknown { return b }
    if b == .unknown { return a }
    return max(a, b)
}
