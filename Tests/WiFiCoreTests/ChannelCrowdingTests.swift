import Testing
@testable import WiFiCore

@Suite struct ChannelCrowdingTests {
    @Test func occupiedChannelsKnownCases() {
        #expect(occupiedChannels(Channel(number: 6, band: .ghz2_4, widthMHz: 20)) == Array(2...10))
        #expect(occupiedChannels(Channel(number: 1, band: .ghz2_4, widthMHz: 20)) == Array(1...5))
        #expect(occupiedChannels(Channel(number: 44, band: .ghz5, widthMHz: 80)) == [36, 40, 44, 48])
        #expect(occupiedChannels(Channel(number: 44, band: .ghz5, widthMHz: 40)) == [44, 48])
        #expect(occupiedChannels(Channel(number: 157, band: .ghz5, widthMHz: 80)) == [149, 153, 157, 161])
        #expect(occupiedChannels(Channel(number: 165, band: .ghz5, widthMHz: 20)) == [165])
        #expect(occupiedChannels(Channel(number: 37, band: .ghz6, widthMHz: 160)) == [33, 37, 41, 45, 49, 53, 57, 61])
    }

    @Test func occupiedChannelsEdgeCases() {
        // 2.4 GHz clamps at the top, whatever the width.
        #expect(occupiedChannels(Channel(number: 13, band: .ghz2_4, widthMHz: 40)) == Array(9...14))
        // Unknown or zero width is treated as 20.
        #expect(occupiedChannels(Channel(number: 44, band: .ghz5, widthMHz: 0)) == [44])
        #expect(occupiedChannels(Channel(number: 44, band: .ghz5, widthMHz: 30)) == [44])
        // 5 GHz channel in no segment.
        #expect(occupiedChannels(Channel(number: 99, band: .ghz5, widthMHz: 80)) == [99])
        // Block running past the end of the segment returns only existing channels.
        #expect(occupiedChannels(Channel(number: 233, band: .ghz6, widthMHz: 160)) == [225, 229, 233])
        // 6 GHz: 320 is treated as 160.
        #expect(occupiedChannels(Channel(number: 37, band: .ghz6, widthMHz: 320)) == [33, 37, 41, 45, 49, 53, 57, 61])
        // Top of the third 5 GHz segment at 80 MHz.
        #expect(occupiedChannels(Channel(number: 177, band: .ghz5, widthMHz: 80)) == [165, 169, 173, 177])
    }

    @Test func outOfRange2_4GHzChannelIsItself() {
        for number in [0, 19, 200, -7] {
            #expect(occupiedChannels(Channel(number: number, band: .ghz2_4, widthMHz: 20)) == [number])
        }
    }

    @Test func loadsCountOverlap() {
        let scan = [
            ap("A", "AA:BB:CC:00:00:01", rssi: -50, ch: 1, band: .ghz2_4, width: 20),
            ap("B", "AA:BB:CC:00:00:02", rssi: -70, ch: 6, band: .ghz2_4, width: 20),
        ]
        let loads = channelLoads(scan)
        let three = loads.first { $0.band == .ghz2_4 && $0.channel == 3 }
        #expect(three?.count == 2)
        #expect(three?.strongestRSSI == -50)
        #expect(!loads.contains { $0.band == .ghz2_4 && $0.channel == 11 })
    }

    @Test func loadsSortedAndCountEveryEntry() {
        let scan = [
            ap(nil, nil, rssi: -60, ch: 44, band: .ghz5, width: 20),
            ap("X", nil, rssi: -40, ch: 6, band: .ghz2_4, width: 20),
        ]
        let loads = channelLoads(scan)
        #expect(loads.first?.band == .ghz2_4)
        #expect(loads.last == ChannelLoad(band: .ghz5, channel: 44, count: 1, strongestRSSI: -60))
        #expect(loads == loads.sorted { ($0.band, $0.channel) < ($1.band, $1.channel) })
    }
}
