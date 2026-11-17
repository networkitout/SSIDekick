import Testing
import WiFiCore

@Suite struct NotificationContentTests {
    private func finding(_ signal: Signal, bssid: String? = "a4:b1:c2:00:00:02") -> Finding {
        Finding(signal: signal, ssid: "Cafe", bssid: bssid.flatMap { MACAddress($0) }, reason: "Because.")
    }

    @Test func strongSignalIsSuspectTwin() {
        let content = notificationContent(for: finding(.clonedAddress))
        #expect(content.title == "Suspect twin: Cafe")
        #expect(content.body == "Because.")
    }

    @Test func mediumAndWeakAreWorthALook() {
        #expect(notificationContent(for: finding(.vendorMismatch)).title == "Worth a look: Cafe")
        #expect(notificationContent(for: finding(.countryMismatch)).title == "Worth a look: Cafe")
    }

    @Test func identifierIsStableAndDistinguishes() {
        let a = notificationContent(for: finding(.clonedAddress))
        #expect(a.identifier == notificationContent(for: finding(.clonedAddress)).identifier)
        #expect(a.identifier != notificationContent(for: finding(.clonedAddress, bssid: "a4:b1:c2:00:00:03")).identifier)
        #expect(a.identifier != notificationContent(for: finding(.gatewayChanged)).identifier)
        #expect(a.identifier != notificationContent(for: finding(.clonedAddress, bssid: nil)).identifier)
    }
}
