import Charts
import SwiftUI
import WiFiCore

/// One bar chart per band present in the scan: bar height is how many access points occupy the channel,
/// bar opacity is the strongest signal on it. The connected channel is outlined.
struct ChannelCrowdingView: View {
    let snapshot: Snapshot

    var body: some View {
        let loads = channelLoads(snapshot.scan)
        let bands = Array(Set(loads.map(\.band))).sorted()
        if bands.isEmpty {
            Text("No networks found yet. Use Scan now.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ForEach(bands, id: \.self) { band in
                        chart(band: band, loads: loads.filter { $0.band == band })
                    }
                    Text("Bar height: access points on the channel. Darker bars have a stronger signal. Outlined: your channel.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(12)
            }
        }
    }

    private func chart(band: Band, loads: [ChannelLoad]) -> some View {
        let connected = snapshot.link.flatMap { $0.channel.band == band ? $0.channel.number : nil }
        let labels = loads.map { String($0.channel) }
        return VStack(alignment: .leading, spacing: 4) {
            Text(bandName(band)).font(.headline)
            Chart(loads, id: \.channel) { load in
                BarMark(x: .value("Channel", String(load.channel)), y: .value("Access points", load.count))
                    .foregroundStyle(Color.accentColor.opacity(signalOpacity(rssi: load.strongestRSSI)))
            }
            .chartXScale(domain: labels)
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let connected, labels.contains(String(connected)), let plot = proxy.plotFrame,
                       let x = proxy.position(forX: String(connected)) {
                        let frame = geometry[plot]
                        let step = frame.width / CGFloat(max(1, labels.count))
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.primary, lineWidth: 2)
                            .frame(width: step * 0.9, height: frame.height)
                            .position(x: frame.minX + x, y: frame.midY)
                    }
                }
            }
            .frame(height: 160)
        }
    }
}
