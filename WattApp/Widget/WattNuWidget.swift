import SwiftUI
import WidgetKit

struct WattNuEntry: TimelineEntry {
    let date: Date
    let reading: NowReading?
    /// True als de server niet bereikbaar was en dit de laatst bekende meting is.
    var isCached = false
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

    /// Lukt ophalen niet, dan tonen we de laatst bekende meting met het
    /// tijdstip erbij in plaats van een lege widget.
    private func loadEntry() async -> WattNuEntry {
        if let reading = try? await APIClient.current?.now() {
            AppSettings.cacheReading(reading)
            return WattNuEntry(date: .now, reading: reading)
        }
        guard APIClient.current != nil, let cached = AppSettings.cachedReading else {
            return WattNuEntry(date: .now, reading: nil)
        }
        return WattNuEntry(date: .now, reading: cached, isCached: true)
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
        content
            .containerBackground(.fill.tertiary, for: .widget)
    }

    @ViewBuilder
    private var content: some View {
        if let reading = entry.reading {
            #if os(iOS)
            if family == .accessoryCircular {
                circular(reading)
            } else if family == .accessoryRectangular {
                rectangular(reading)
            } else if family == .accessoryInline {
                Text("\(Format.power(reading.powerTotal)) · \(Format.number(reading.todayKwh)) kWh")
            } else if family == .systemMedium {
                medium(reading)
            } else {
                small(reading)
            }
            #else
            if family == .systemMedium {
                medium(reading)
            } else {
                small(reading)
            }
            #endif
        } else {
            Text("Geen verbinding")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Ondertitel: verbruik van vandaag, of het tijdstip van een oude meting.
    private func subtitle(_ reading: NowReading) -> Text {
        if entry.isCached, let time = reading.time {
            return Text("Laatst \(time, style: .time)")
        }
        return Text("Vandaag \(Format.number(reading.todayKwh)) kWh")
    }

    private func highestPhase(_ reading: NowReading) -> Double {
        reading.currents.dropLast().map(\.amps).max() ?? 0
    }

    #if os(iOS)
    private func circular(_ reading: NowReading) -> some View {
        Gauge(value: min(highestPhase(reading), AppSettings.fuseAmps), in: 0...AppSettings.fuseAmps) {
            Image(systemName: "bolt.fill")
        } currentValueLabel: {
            Text(Format.number((reading.powerTotal ?? 0) / 1000))
        }
        .gaugeStyle(.accessoryCircular)
        .accessibilityLabel("Vermogen")
        .accessibilityValue(Format.power(reading.powerTotal))
    }

    private func rectangular(_ reading: NowReading) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(Format.power(reading.powerTotal))
                .font(.headline.monospacedDigit())
            subtitle(reading)
            Text(reading.currents.dropLast()
                .map { "\($0.name) \(Format.number($0.amps, decimals: 0))" }
                .joined(separator: " · ") + " A")
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    #endif

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
            subtitle(reading)
                .font(.caption2)
                .foregroundStyle(reading.stale || entry.isCached ? Color.orange : Color.secondary)
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
    /// Vergrendelschermwidgets bestaan alleen op iOS.
    private static var families: [WidgetFamily] {
        #if os(iOS)
        return [.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        return [.systemSmall, .systemMedium]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WattNuWidget", provider: WattNuProvider()) { entry in
            WattNuWidgetView(entry: entry)
        }
        .configurationDisplayName("WattNu")
        .description("Vermogen en stroom per fase.")
        .supportedFamilies(Self.families)
    }
}
