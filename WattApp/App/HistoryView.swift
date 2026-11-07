import Charts
import SwiftUI

enum HistorySpan: Int, CaseIterable, Identifiable {
    case hour = 1, day = 24, week = 168, month = 720

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .hour: return "1 uur"
        case .day: return "24 uur"
        case .week: return "7 dagen"
        case .month: return "30 dagen"
        }
    }
}

enum HistoryMetric: String, CaseIterable, Identifiable {
    case current = "Stroom"
    case power = "Vermogen"
    case voltage = "Spanning"

    var id: String { rawValue }
    var unit: String {
        switch self {
        case .current: return "A"
        case .power: return "W"
        case .voltage: return "V"
        }
    }
    var names: [String] { self == .current ? PhaseStyle.names : ["L1", "L2", "L3"] }

    func values(_ point: SeriesPoint) -> [Double?] {
        switch self {
        case .current: return [point.currentL1, point.currentL2, point.currentL3, point.currentN]
        case .power: return [point.powerL1, point.powerL2, point.powerL3]
        case .voltage: return [point.voltageL1, point.voltageL2, point.voltageL3]
        }
    }
}

struct ChartValue: Identifiable {
    let time: Date
    let phase: String
    let value: Double

    var id: String { "\(phase)-\(time.timeIntervalSince1970)" }
}

struct HistoryView: View {
    @State private var span = HistorySpan.day
    @State private var metric = HistoryMetric.current
    @State private var points: [SeriesPoint] = []
    @State private var errorText: String?
    @State private var isLoading = false
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true

    private var values: [ChartValue] {
        let names = metric.names
        return points.flatMap { point in
            zip(names, metric.values(point)).compactMap { name, value in
                value.map { ChartValue(time: point.time, phase: name, value: $0) }
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Picker("Periode", selection: $span) {
                ForEach(HistorySpan.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Meting", selection: $metric) {
                ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if let errorText {
                Banner(text: errorText, systemImage: "wifi.exclamationmark")
            }

            if isLoading && points.isEmpty {
                ProgressView("Metingen ophalen…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if values.isEmpty {
                MeasurementPlaceholder(
                    title: "Nog geen metingen",
                    detail: pieterMode ? PieterCopy.noHistory : "Voor deze periode zijn geen metingen beschikbaar."
                )
                .frame(maxHeight: .infinity)
            } else {
                Chart(values) { item in
                    LineMark(
                        x: .value("Tijd", item.time),
                        y: .value("Waarde", item.value),
                        series: .value("Fase", item.phase)
                    )
                    .foregroundStyle(by: .value("Fase", item.phase))
                }
                .chartForegroundStyleScale(domain: metric.names, range: metric.names.map(PhaseStyle.color))
                .chartYScale(domain: .automatic(includesZero: metric != .voltage))
                .chartYAxisLabel { Text(metric.unit) }
                .chartLegend(position: .bottom, spacing: 12)
                .frame(maxHeight: .infinity)
            }
        }
        .padding()
        .task(id: span) { await load() }
    }

    private func load() async {
        guard let client = APIClient.current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            points = try await client.series(hours: span.rawValue)
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
