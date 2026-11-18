import Foundation
import Testing
import WiFiSystem

@Suite struct StoredSettingsTests {
    @Test func intervalMapping() {
        #expect(scanInterval(fromStoredSeconds: 0) == nil)
        #expect(scanInterval(fromStoredSeconds: 30) == 30)
        #expect(scanInterval(fromStoredSeconds: 60) == 60)
        #expect(scanInterval(fromStoredSeconds: 300) == 300)
        #expect(scanInterval(fromStoredSeconds: nil) == 60)
        #expect(scanInterval(fromStoredSeconds: 45) == 60)
        #expect(scanInterval(fromStoredSeconds: -1) == 60)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "wifiutil.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func missingKeysGiveDefaults() {
        let settings = loadEngineSettings(from: freshDefaults())
        #expect(settings == EngineSettings(scanInterval: 60, publicIPEnabled: true))
    }

    @Test func storedValuesAreLoaded() {
        let defaults = freshDefaults()
        defaults.set(0, forKey: SettingsKey.scanIntervalSeconds)
        defaults.set(false, forKey: SettingsKey.publicIPEnabled)
        #expect(loadEngineSettings(from: defaults) == EngineSettings(scanInterval: nil, publicIPEnabled: false))
        defaults.set(300, forKey: SettingsKey.scanIntervalSeconds)
        #expect(loadEngineSettings(from: defaults).scanInterval == 300)
    }

    @Test func interceptionChecksDefaultOn() {
        #expect(loadEngineSettings(from: freshDefaults()).interceptionChecksEnabled)
    }

    @Test func interceptionChecksStoredOff() {
        let defaults = freshDefaults()
        defaults.set(false, forKey: SettingsKey.interceptionChecksEnabled)
        #expect(!loadEngineSettings(from: defaults).interceptionChecksEnabled)
    }
}
