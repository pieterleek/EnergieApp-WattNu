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
                Card(title: "Hoogste pieken") { peakList }
            }
            .padding()
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await load() }
        .task { await load() }
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

    private var peakList: some View {
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
