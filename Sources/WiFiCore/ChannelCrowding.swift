import Foundation

/// Channel numbers of the same band that a transmission on `channel` overlaps.
public func occupiedChannels(_ channel: Channel) -> [Int] {
    let number = channel.number
    switch channel.band {
    case .ghz2_4:
        guard (1...14).contains(number) else { return [number] }
        return Array(max(1, number - 4)...min(14, number + 4))
    case .ghz5:
        let segments = [36...64, 100...144, 149...177]
        guard let segment = segments.first(where: { $0.contains(number) }) else { return [number] }
        return block(of: number, in: segment, widthMHz: channel.widthMHz)
    case .ghz6:
        let width = channel.widthMHz == 320 ? 160 : channel.widthMHz
        let segment = 1...233
        guard segment.contains(number) else { return [number] }
        return block(of: number, in: segment, widthMHz: width)
    }
}

/// The aligned block of 20 MHz channels (4 apart) that contains `number`, limited to the segment.
private func block(of number: Int, in segment: ClosedRange<Int>, widthMHz: Int) -> [Int] {
    let n = widthMHz > 0 && widthMHz % 20 == 0 ? widthMHz / 20 : 1
    let index = (number - segment.lowerBound) / 4
    let blockStart = index / n * n
    return (blockStart..<(blockStart + n))
        .map { segment.lowerBound + $0 * 4 }
        .filter { segment.contains($0) }
}

public struct ChannelLoad: Sendable, Hashable {
    public var band: Band
    public var channel: Int
    public var count: Int
    public var strongestRSSI: Int

    public init(band: Band, channel: Int, count: Int, strongestRSSI: Int) {
        self.band = band
        self.channel = channel
        self.count = count
        self.strongestRSSI = strongestRSSI
    }
}

private struct ChannelKey: Hashable {
    var band: Band
    var channel: Int
}

/// How busy each channel is: every access point counts on every channel it occupies.
/// Only channels with at least one access point appear, sorted by band then channel.
public func channelLoads(_ scan: [AccessPoint]) -> [ChannelLoad] {
    var loads: [ChannelKey: ChannelLoad] = [:]
    for accessPoint in scan {
        let band = accessPoint.channel.band
        for number in occupiedChannels(accessPoint.channel) {
            let key = ChannelKey(band: band, channel: number)
            if var load = loads[key] {
                load.count += 1
                load.strongestRSSI = max(load.strongestRSSI, accessPoint.rssi)
                loads[key] = load
            } else {
                loads[key] = ChannelLoad(band: band, channel: number, count: 1, strongestRSSI: accessPoint.rssi)
            }
        }
    }
    return loads.values.sorted { ($0.band, $0.channel) < ($1.band, $1.channel) }
}
