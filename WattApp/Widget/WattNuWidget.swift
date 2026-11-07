import SwiftUI
import WidgetKit

struct WattNuEntry: TimelineEntry {
    let date: Date
    let reading: NowReading?
}

struct WattNuProvider: TimelineProvider {
    func placeholder(in context: Context) -> WattNuEntry {
        WattNuEntry(date: .now, reading: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (WattNuEntry) -> Void) {
        if context.isPreview {
            completion(WattNuEntry(date: .now, reading: .sample))
            return
        }
        Task { completion(await loadEntry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WattNuEntry>) -> Void) {
        Task {
            let next = Date.now.addingTimeInterval(15 * 60)
            completion(Timeline(entries: [await loadEntry()], policy: .after(next)))
        }
    }

    private func loadEntry() async -> WattNuEntry {
        let reading = try? await APIClient.current?.now()
        return WattNuEntry(date: .now, reading: reading)
    }
}

extension NowReading {
    static let sample = NowReading(
        time: .now, currentL1: 6.2, currentL2: 3.1, currentL3: 9.4, currentN: 5.5,
        powerTotal: 4210, todayKwh: 8.4, monthKwh: 96, stale: false)
}

struct WattNuWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WattNuEntry

    var body: some View {
        Group {
            if let reading = entry.reading {
                switch family {
                case .systemMedium: medium(reading)
                default: small(reading)
                }
            } else {
                Text("Geen verbinding")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func small(_ reading: NowReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summary(reading)
            bars(reading, height: 44)
        }
    }

    private func medium(_ reading: NowReading) -> some View {
        HStack(spacing: 16) {
            summary(reading)
            bars(reading, height: 92)
        }
    }

    private func summary(_ reading: NowReading) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Format.power(reading.powerTotal))
                .font(.system(.title2, design: .rounded).weight(.bold).monospacedDigit())
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("Vandaag \(Format.number(reading.todayKwh)) kWh")
                .font(.caption2)
                .foregroundStyle(reading.stale ? Color.orange : Color.secondary)
        }
    }

    private func bars(_ reading: NowReading, height: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(reading.currents, id: \.name) { phase in
                PhaseBar(name: phase.name, amps: phase.amps, fuse: AppSettings.fuseAmps,
                         height: height, showsValue: false)
            }
        }
    }
}

@main
struct WattNuWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WattNuWidget", provider: WattNuProvider()) { entry in
            WattNuWidgetView(entry: entry)
        }
        .configurationDisplayName("WattNu")
        .description("Vermogen en stroom per fase.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
