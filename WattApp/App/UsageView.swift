import Charts
import SwiftUI

struct UsageView: View {
    @State private var days: [DayUsage] = []
    @State private var cells: [HeatCell] = []
    @State private var peaks: [Peak] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    private let weekdays = ["Ma", "Di", "Wo", "Do", "Vr", "Za", "Zo"]
    private let hours = (0..<24).map { String(format: "%02d", $0) }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let errorText {
                    Banner(text: errorText, systemImage: "wifi.exclamationmark")
                }
                Card(title: "Verbruik per dag") { dailyChart }
                Card(title: "Wanneer gebruik ik het meest?") { heatmap }
                Card(title: "Hoogste pieken thuis") { homePeakList }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private var homePeakList: some View {
        Group {
            if peaks.isEmpty {
                MeasurementPlaceholder(
                    title: "Geen pieken",
                    detail: pieterMode ? PieterCopy.noPeaks : "Er zijn nog geen verbruikspieken gevonden.",
                    systemImage: "waveform.path.ecg"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(peaks) { peak in
                        HStack {
                            Text(peak.time.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Format.power(peak.powerTotal)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var dailyChart: some View {
        Group {
            if isLoading && days.isEmpty {
                ProgressView("Verbruik ophalen…").frame(maxWidth: .infinity, minHeight: 220)
            } else if days.isEmpty {
                MeasurementPlaceholder(
                    title: "Nog geen dagverbruik",
                    detail: "Zodra er data is, verschijnt hier het verbruik per fase."
                )
            } else {
                Chart(days) { day in
                    ForEach(Array(zip(["L1", "L2", "L3"], [day.kwhL1, day.kwhL2, day.kwhL3])), id: \.0) { name, kwh in
                        BarMark(
                            x: .value("Dag", day.day, unit: .day),
                            y: .value("kWh", kwh ?? 0)
                        )
                        .foregroundStyle(by: .value("Fase", name))
                    }
                }
                .chartForegroundStyleScale(domain: ["L1", "L2", "L3"], range: [Color.l1, Color.l2, Color.l3])
                .chartLegend(position: .bottom, spacing: 12)
                .frame(height: 220)
            }
        }
    }

    private var heatmap: some View {
        let validCells = cells.filter { (1...7).contains($0.weekday) && (0..<24).contains($0.hour) }
        let highest = max(validCells.map(\.kwh).max() ?? 1, 0.001)
        return Group {
            if validCells.isEmpty {
                MeasurementPlaceholder(
                    title: "Nog geen patroon",
                    detail: "Na een tijdje meten zie je hier op welke uren het huis het drukst is."
                )
            } else {
                Chart(validCells) { cell in
                    RectangleMark(
                        x: .value("Uur", hours[cell.hour]),
                        y: .value("Dag", weekdays[cell.weekday - 1]),
                        width: .ratio(0.92),
                        height: .ratio(0.92)
                    )
                    .foregroundStyle(Color.orange.opacity(0.08 + 0.92 * cell.kwh / highest))
                }
                .chartXScale(domain: hours)
                .chartYScale(domain: weekdays)
                .chartXAxis {
                    AxisMarks(values: ["00", "06", "12", "18"]) { _ in
                        AxisValueLabel()
                    }
                }
                .frame(height: 230)
            }
        }
    }

    private func load() async {
        guard let client = APIClient.current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let dailyResult = client.daily()
            async let heatResult = client.heatmap()
            async let peakResult = client.peaks()
            (days, cells, peaks) = try await (dailyResult, heatResult, peakResult)
            errorText = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}

enum GridSpan: Int, CaseIterable, Identifiable {
    case day = 1
    case week = 7
    case month = 30

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .day: return "24 uur"
        case .week: return "7 dagen"
        case .month: return "30 dagen"
        }
    }
}

struct GridLoadView: View {
    @State private var span = GridSpan.week
    @State private var response: GridLoadResponse?
    @State private var errorText: String?
    @State private var isLoading = false
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true

    private var points: [GridLoadPoint] { response?.points ?? [] }
    private var latest: GridLoadPoint? { points.max { $0.time < $1.time } }
    private var highest: GridLoadPoint? { points.max { $0.loadMw < $1.loadMw } }
    private var lowest: GridLoadPoint? { points.min { $0.loadMw < $1.loadMw } }
    private var topPeaks: [GridLoadPoint] {
        Array(points.sorted { $0.loadMw > $1.loadMw }.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Periode", selection: $span) {
                    ForEach(GridSpan.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if let errorText {
                    Banner(text: errorText, systemImage: "wifi.exclamationmark")
                }

                if response?.stale == true {
                    Banner(
                        text: "De bron reageert even niet; je ziet de laatst opgehaalde netdata.",
                        systemImage: "clock.arrow.circlepath"
                    )
                }

                if isLoading && points.isEmpty {
                    ProgressView("Nederlandse netbelasting ophalen…")
                        .frame(maxWidth: .infinity, minHeight: 220)
                } else if points.isEmpty {
                    MeasurementPlaceholder(
                        title: "Geen netdata",
                        detail: "De landelijke belasting is op dit moment niet beschikbaar.",
                        systemImage: "network.slash"
                    )
                } else {
                    Card(title: "Nederland nu") { summary }
                    Card(title: "Belasting van het stroomnet") { gridChart }
                    Card(title: "Hoogste kwartieren") { peakList }
                    if pieterMode {
                        Card(title: "Pieters netrapport") {
                            Text(pieterSummary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Bron: \(response?.source ?? "Energy-Charts.info") · \(response?.license ?? "CC BY 4.0")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .task(id: span) { await load() }
    }

    private var summary: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Belasting nu")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatGigawatts(latest?.loadMw))
                    .font(.title2.bold().monospacedDigit())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("Piek in periode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatGigawatts(highest?.loadMw))
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(.orange)
            }
        }
    }

    private var gridChart: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Moment", point.time),
                y: .value("Belasting", point.loadMw / 1000)
            )
            .foregroundStyle(.linearGradient(
                colors: [.orange.opacity(0.5), .orange.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            ))
            LineMark(
                x: .value("Moment", point.time),
                y: .value("Belasting", point.loadMw / 1000)
            )
            .foregroundStyle(.orange)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYAxisLabel("GW")
        .frame(height: 230)
    }

    private var peakList: some View {
        VStack(spacing: 12) {
            ForEach(topPeaks) { peak in
                HStack {
                    Text(peak.time.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(formatGigawatts(peak.loadMw))
                        .font(.headline.monospacedDigit())
                }
                if peak.id != topPeaks.last?.id { Divider() }
            }
        }
    }

    private func formatGigawatts(_ megawatts: Double?) -> String {
        guard let megawatts else { return "–" }
        return Format.number(megawatts / 1000, decimals: 2) + " GW"
    }

    private var pieterSummary: String {
        guard let latest, let highest, let lowest else { return PieterCopy.noPeaks }
        let range = highest.loadMw - lowest.loadMw
        if latest.loadMw > lowest.loadMw + range * 0.8 {
            return "Nederland zit dicht bij de piek. Heel het land heeft blijkbaar tegelijk de waterkoker ontdekt."
        }
        if latest.loadMw < lowest.loadMw + range * 0.25 {
            return "Het net heeft een rustig kwartiertje. Zelfs de elektronen lijken koffiepauze te hebben."
        }
        return "Het landelijk net draait in de middenmoot. Druk genoeg om belangrijk te lijken, rustig genoeg om niet te zweten."
    }

    private func load() async {
        guard let client = APIClient.current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            response = try await client.gridLoad(days: span.rawValue)
            errorText = nil
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}
