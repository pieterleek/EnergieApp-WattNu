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
    @State private var points: [SeriesPoint]
    @State private var selectedDate: Date?
    @State private var errorText: String?
    @State private var isLoading = false
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    private let isPreview: Bool

    init(previewPoints: [SeriesPoint]? = nil) {
        _points = State(initialValue: previewPoints ?? [])
        self.isPreview = previewPoints != nil
    }

    private var selectedPoint: SeriesPoint? {
        guard let selectedDate, !points.isEmpty else { return nil }
        return points.min {
            abs($0.time.timeIntervalSince(selectedDate)) < abs($1.time.timeIntervalSince(selectedDate))
        }
    }

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

            HStack(spacing: 10) {
                Picker("Meting", selection: $metric) {
                    ForEach(HistoryMetric.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityLabel("Verversen")
            }

            if let errorText {
                Banner(text: errorText, systemImage: "wifi.exclamationmark")
            }

            if let point = selectedPoint {
                selectedBanner(point)
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
                Chart {
                    ForEach(values) { item in
                        LineMark(
                            x: .value("Tijd", item.time),
                            y: .value("Waarde", item.value),
                            series: .value("Fase", item.phase)
                        )
                        .foregroundStyle(by: .value("Fase", item.phase))
                    }
                    if let point = selectedPoint {
                        RuleMark(x: .value("Geselecteerd", point.time))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartForegroundStyleScale(domain: metric.names, range: metric.names.map(PhaseStyle.color))
                .chartYScale(domain: .automatic(includesZero: metric != .voltage))
                .chartYAxisLabel { Text(metric.unit) }
                .chartXSelection(value: $selectedDate)
                .chartLegend(position: .bottom, spacing: 12)
                .frame(maxHeight: .infinity)
                .accessibilityLabel("\(metric.rawValue) per fase, \(span.label)")
            }
        }
        .padding()
        .task(id: span) {
            selectedDate = nil
            await load()
        }
    }

    private func selectedBanner(_ point: SeriesPoint) -> some View {
        let readings = zip(metric.names, metric.values(point)).compactMap { name, value -> String? in
            guard let value else { return nil }
            let decimals = metric == .current ? 1 : 0
            return "\(name) \(Format.number(value, decimals: decimals)) \(metric.unit)"
        }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 2) {
            Text(point.time.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(readings)
                .font(.subheadline.monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func load() async {
        guard !isPreview, let client = APIClient.current else { return }
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

#Preview("Verloop") {
    let now = Date()
    let sample = (0..<48).map { idx -> SeriesPoint in
        let t = now.addingTimeInterval(Double(idx - 47) * 1800)
        let wave = sin(Double(idx) / 5.0)
        return SeriesPoint(
            time: t,
            currentL1: 4.5 + wave * 3.0,
            currentL2: 2.2 + cos(Double(idx) / 6.0) * 1.4,
            currentL3: 6.0 + max(wave, 0) * 5.0,
            currentN: 3.1 + abs(wave) * 1.8,
            powerL1: (4.5 + wave * 3.0) * 230,
            powerL2: (2.2 + cos(Double(idx) / 6.0) * 1.4) * 230,
            powerL3: (6.0 + max(wave, 0) * 5.0) * 230,
            powerTotal: 2800 + wave * 1400,
            voltageL1: 232 + wave * 2,
            voltageL2: 234 - wave * 1.5,
            voltageL3: 231 + cos(Double(idx) / 4.0) * 2
        )
    }
    return HistoryView(previewPoints: sample)
}
