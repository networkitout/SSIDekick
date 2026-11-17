import Foundation

public enum Strength: Int, Sendable, Comparable {
    case weak, medium, strong

    public static func < (lhs: Strength, rhs: Strength) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum Signal: String, Sendable, CaseIterable {
    // strong
    case securityMismatch, clonedAddress, gatewayChanged, dnsChanged, dnsTampered
    // medium
    case vendorMismatch, louderNewcomer, movedToFlagged
    // weak
    case locallyAdministered, countryMismatch, beaconMismatch, generationMismatch

    public var strength: Strength {
        switch self {
        case .securityMismatch, .clonedAddress, .gatewayChanged, .dnsChanged, .dnsTampered: .strong
        case .vendorMismatch, .louderNewcomer, .movedToFlagged: .medium
        case .locallyAdministered, .countryMismatch, .beaconMismatch, .generationMismatch: .weak
        }
    }
}

public struct Finding: Sendable, Hashable {
    public var signal: Signal
    public var ssid: String
    /// nil means the finding applies to the connection as a whole (gateway, DNS).
    public var bssid: MACAddress?
    /// One line, user-facing.
    public var reason: String

    public init(signal: Signal, ssid: String, bssid: MACAddress?, reason: String) {
        self.signal = signal
        self.ssid = ssid
        self.bssid = bssid
        self.reason = reason
    }
}

public enum Verdict: Int, Sendable, Comparable {
    case clear, note, worthALook, suspect

    public static func < (lhs: Verdict, rhs: Verdict) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Scores the findings of one access point.
public func verdict(for findings: [Finding]) -> Verdict {
    let strengths = findings.map(\.signal.strength)
    if strengths.contains(.strong) { return .suspect }
    if strengths.contains(.medium) || strengths.filter({ $0 == .weak }).count >= 2 { return .worthALook }
    if strengths.contains(.weak) { return .note }
    return .clear
}

/// The worst verdict among the access points (and the connection itself) of one network name.
public func networkVerdict(ssid: String, findings: [Finding]) -> Verdict {
    let mine = findings.filter { $0.ssid == ssid }
    let addresses = Set(mine.map(\.bssid))
    return addresses
        .map { address in verdict(for: mine.filter { $0.bssid == address }) }
        .max() ?? .clear
}
