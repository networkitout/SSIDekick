import Testing
import Foundation
@testable import WiFiCore

@Suite struct SnapshotTests {
    @Test func lossIsNilWhenEmpty() {
        #expect(LossWindow().lossPercent == nil)
    }

    @Test func threeFailuresInTwentyIsFifteenPercent() {
        var window = LossWindow()
        for i in 0..<20 { window.record(success: i >= 3) }
        #expect(window.lossPercent == 15)
    }

    @Test func twentyFirstRecordEvictsOldest() {
        var window = LossWindow()
        window.record(success: false)
        for _ in 0..<19 { window.record(success: true) }
        #expect(window.lossPercent == 5)
        window.record(success: true)
        #expect(window.lossPercent == 0)
    }

    @Test func lossRoundsToNearestPercent() {
        var window = LossWindow()
        window.record(success: false)
        window.record(success: true)
        window.record(success: true)
        #expect(window.lossPercent == 33)
    }

    @Test func cadenceValues() {
        #expect(Cadence.linkInterval(menuOpen: true) == 1)
        #expect(Cadence.linkInterval(menuOpen: false) == 10)
        #expect(Cadence.probeInterval(menuOpen: true) == 5)
        #expect(Cadence.probeInterval(menuOpen: false) == 30)
    }

    @Test func emptySnapshotAndConnectivityDefaults() {
        let snapshot = Snapshot.empty
        #expect(snapshot.state == .notConnected)
        #expect(!snapshot.locationAuthorized)
        #expect(snapshot.link == nil)
        #expect(snapshot.scan.isEmpty)
        #expect(snapshot.findings.isEmpty)
        #expect(snapshot.connectedVerdict == .clear)
        #expect(snapshot.connectivity == ConnectivitySnapshot())
        #expect(ConnectivitySnapshot().internet == .unknown)
    }
}
