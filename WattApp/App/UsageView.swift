import Charts
import SwiftUI

struct UsageView: View {
    @State private var days: [DayUsage]
    @State private var cells: [HeatCell]
    @State private var peaks: [Peak]
    @State private var baseload: [BaseloadDay]
    @State private var comparison: Comparison?
    @State private var errorText: String?
    @State private var isLoading = false
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    @AppStorage(AppSettings.Key.priceImport, store: AppSettings.store) private var priceImport = 0.0
    @AppStorage(AppSettings.Key.priceExport, store: AppSettings.store) private var priceExport = 0.0
    private let isPreview: Bool
    private let weekdayNames = ["maandag", "dinsdag", "woensdag", "donderdag", "vrijdag", "zaterdag", "zondag"]
    private let weekdays = ["Ma", "Di", "Wo", "Do", "Vr", "Za", "Zo"]
    private let hours = (0..<24).map { String(format: "%02d", $0) }

    init(
        previewDays: [DayUsage]? = nil,
        previewCells: [HeatCell]? = nil,
        previewPeaks: [Peak]? = nil,
        previewBaseload: [BaseloadDay]? = nil,
        previewComparison: Comparison? = nil
    ) {
        _days = State(initialValue: previewDays ?? [])
        _cells = State(initialValue: previewCells ?? [])
        _peaks = State(initialValue: previewPeaks ?? [])
        _baseload = State(initialValue: previewBaseload ?? [])
        _comparison = State(initialValue: previewComparison)
        self.isPreview = previewDays != nil
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let errorText {
                    Banner(text: errorText, systemImage: "wifi.exclamationmark")
                }
                if let comparison, comparison.weekKwh != nil || comparison.monthKwh != nil {
                    Card(title: "Tot nu toe") { comparisonList(comparison) }
                }
                Card(title: "Verbruik per dag") { dailyChart }
                if days.contains(where: { ($0.kwhExport ?? 0) > 0 }) {
                    Card(title: "Teruglevering per dag") { exportChart }
                }
                if !baseload.isEmpty {
                    Card(title: "Sluipverbruik") { baseloadCard }
                }
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

    // MARK: Vergelijking

    private func comparisonList(_ comparison: Comparison) -> some View {
        VStack(spacing: 12) {
            ComparisonRow(
                label: "Deze week", kwh: comparison.weekKwh, exportKwh: comparison.weekExportKwh,
                reference: comparison.previousWeekKwh, referenceLabel: "vorige week",
                cost: cost(comparison.weekKwh, comparison.weekExportKwh)
            )
            Divider()
            ComparisonRow(
                label: "Deze maand", kwh: comparison.monthKwh, exportKwh: comparison.monthExportKwh,
                reference: comparison.previousMonthKwh, referenceLabel: "vorige maand",
                cost: cost(comparison.monthKwh, comparison.monthExportKwh)
            )
            if let lastYear = comparison.lastYearMonthKwh, lastYear > 0 {
                ComparisonRow(
                    label: "Zelfde maand vorig jaar", kwh: lastYear,
                    exportKwh: comparison.lastYearMonthExportKwh,
                    reference: nil, referenceLabel: "",
                    cost: cost(lastYear, comparison.lastYearMonthExportKwh)
                )
            }
            Text("Vergeleken met hetzelfde aantal dagen en uren van de vorige periode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cost(_ importKwh: Double?, _ exportKwh: Double?) -> Double? {
        Format.cost(importKwh: importKwh, exportKwh: exportKwh,
                    priceImport: priceImport, priceExport: priceExport)
    }

    // MARK: Teruglevering

    private var exportChart: some View {
        let total = days.reduce(0) { $0 + ($1.kwhExport ?? 0) }
        return Chart(days) { day in
            BarMark(
                x: .value("Dag", day.day, unit: .day),
                y: .value("kWh", day.kwhExport ?? 0)
            )
            .foregroundStyle(Color.l3)
        }
        .frame(height: 160)
        .accessibilityLabel("Teruglevering per dag")
        .accessibilityValue("\(Format.number(total)) kilowattuur in \(days.count) dagen")
    }

    // MARK: Sluipverbruik

    private var baseloadCard: some View {
        let average = baseload.map(\.watts).reduce(0, +) / Double(baseload.count)
        let yearlyKwh = max(average, 0) * 24 * 365 / 1000
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Format.power(average))
                    .font(.title2.bold().monospacedDigit())
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("≈ \(Format.number(yearlyKwh, decimals: 0)) kWh per jaar")
                    if priceImport > 0 {
                        Text("≈ \(Format.euro(yearlyKwh * priceImport)) per jaar")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Chart(baseload) { night in
                BarMark(
                    x: .value("Nacht", night.day, unit: .day),
                    y: .value("Watt", night.watts)
                )
                .foregroundStyle(Color.l2)
            }
            .chartYAxisLabel("W")
            .frame(height: 140)
            .accessibilityLabel("Sluipverbruik per nacht")
            .accessibilityValue("Gemiddeld \(Format.power(average))")
            Text("Wat het huis 's nachts tussen 0 en 5 uur minimaal blijft gebruiken: koelkast, router, stand-by. Dit draait het hele jaar door.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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
                .accessibilityLabel("Verbruik per dag, per fase")
                .accessibilityValue("\(Format.number(days.reduce(0) { $0 + ($1.kwhTotal ?? 0) })) kilowattuur in \(days.count) dagen")
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
                    .accessibilityLabel("\(weekdayNames[cell.weekday - 1]) \(cell.hour) uur")
                    .accessibilityValue("\(Format.number(cell.kwh, decimals: 2)) kilowattuur gemiddeld")
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
        guard !isPreview, let client = APIClient.current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let dailyResult = client.daily()
            async let heatResult = client.heatmap()
            async let peakResult = client.peaks()
            // Deze twee ontbreken op een oudere server; dan blijven de kaarten weg.
            async let baseloadResult = try? client.baseload()
            async let comparisonResult = try? client.compare()
            (days, cells, peaks) = try await (dailyResult, heatResult, peakResult)
            baseload = await baseloadResult ?? []
            comparison = await comparisonResult
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

/// Eén periode met het verschil ten opzichte van de vorige.
struct ComparisonRow: View {
    let label: String
    let kwh: Double?
    let exportKwh: Double?
    let reference: Double?
    let referenceLabel: String
    let cost: Double?

    /// Procentueel verschil; nil als er geen zinnige vergelijking is.
    private var change: Double? {
        guard let kwh, let reference, reference > 0 else { return nil }
        return (kwh - reference) / reference
    }

    private var changeText: String? {
        guard let change else { return nil }
        let percent = abs(change).formatted(.percent.precision(.fractionLength(0)))
        if abs(change) < 0.005 { return "gelijk aan \(referenceLabel)" }
        return "\(percent) \(change > 0 ? "meer" : "minder") dan \(referenceLabel)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                Spacer()
                Text(Format.number(kwh) + " kWh")
                    .font(.headline.monospacedDigit())
            }
            HStack(alignment: .firstTextBaseline) {
                if let changeText, let change {
                    Label(changeText, systemImage: change > 0.005 ? "arrow.up.right" : change < -0.005 ? "arrow.down.right" : "equal")
                        .foregroundStyle(change > 0.005 ? Color.orange : Color.secondary)
                }
                Spacer()
                if let cost {
                    Text(Format.euro(cost)).monospacedDigit()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let exportKwh, exportKwh > 0 {
                Text("Teruggeleverd: \(Format.number(exportKwh)) kWh")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Gebruik") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)
    let sampleDays = (0..<14).map { offset -> DayUsage in
        let date = cal.date(byAdding: .day, value: offset - 13, to: today)!
        let l1 = 3.5 + Double(offset % 4) * 0.9
        let l2 = 2.4 + Double((offset + 1) % 3) * 0.8
        let l3 = 4.1 + Double(offset % 5) * 0.7
        return DayUsage(day: date, kwhTotal: l1 + l2 + l3, kwhExport: Double(offset % 3) * 1.4,
                        kwhL1: l1, kwhL2: l2, kwhL3: l3)
    }
    let sampleCells = (1...7).flatMap { day in
        (0..<24).map { hour in
            let evening = (17...21).contains(hour) ? 1.4 : (7...9).contains(hour) ? 0.8 : 0.25
            return HeatCell(weekday: day, hour: hour, kwh: evening + Double((day + hour) % 3) * 0.15)
        }
    }
    let sampleBaseload = sampleDays.map { BaseloadDay(day: $0.day, watts: 185 + Double(Int($0.kwhTotal ?? 0) % 4) * 12) }
    let samplePeaks = [
        Peak(time: .now.addingTimeInterval(-7200), powerTotal: 7840),
        Peak(time: .now.addingTimeInterval(-86400), powerTotal: 6520),
        Peak(time: .now.addingTimeInterval(-172800), powerTotal: 5910),
    ]
    let sampleComparison = Comparison(
        weekKwh: 74.2, weekExportKwh: 12.1, previousWeekKwh: 81.5, previousWeekExportKwh: 9.4,
        monthKwh: 268.0, monthExportKwh: 44.0, previousMonthKwh: 249.0, previousMonthExportKwh: 38.0,
        lastYearMonthKwh: 290.0, lastYearMonthExportKwh: 31.0
    )
    return UsageView(
        previewDays: sampleDays,
        previewCells: sampleCells,
        previewPeaks: samplePeaks,
        previewBaseload: sampleBaseload,
        previewComparison: sampleComparison
    )
}
