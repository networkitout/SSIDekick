import Foundation

public enum SettingsKey {
    public static let scanIntervalSeconds = "scanIntervalSeconds"
    public static let publicIPEnabled = "publicIPEnabled"
    public static let interceptionChecksEnabled = "interceptionChecksEnabled"
}

/// Maps the stored interval to the engine's: 0 is off; 30, 60 and 300 are themselves; anything else
/// (including a missing value) is 60.
public func scanInterval(fromStoredSeconds seconds: Int?) -> TimeInterval? {
    switch seconds {
    case 0: nil
    case 30, 60, 300: TimeInterval(seconds!)
    default: 60
    }
}

public func loadEngineSettings(from defaults: UserDefaults) -> EngineSettings {
    let seconds = defaults.object(forKey: SettingsKey.scanIntervalSeconds) as? Int
    let publicIP = defaults.object(forKey: SettingsKey.publicIPEnabled) as? Bool ?? true
    let interception = defaults.object(forKey: SettingsKey.interceptionChecksEnabled) as? Bool ?? true
    return EngineSettings(scanInterval: scanInterval(fromStoredSeconds: seconds), publicIPEnabled: publicIP,
                          interceptionChecksEnabled: interception)
}
