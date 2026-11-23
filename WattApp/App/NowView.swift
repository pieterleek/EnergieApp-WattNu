import SwiftUI

@MainActor
@Observable
final class NowModel {
    var reading: NowReading?
    var errorText: String?
    private let isPreview: Bool

    init(previewReading: NowReading? = nil) {
        self.reading = previewReading
        self.isPreview = previewReading != nil
    }

    /// Ververst elke 5 seconden zolang het scherm zichtbaar is.
    func poll() async {
        guard !isPreview else { return }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refresh() async {
        guard !isPreview, let client = APIClient.current else { return }
        do {
            let next = try await client.now()
            withAnimation(.easeInOut(duration: 0.6)) { reading = next }
            errorText = nil
            AppSettings.cacheReading(next)
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            errorText = error.localizedDescription
        }
    }
}

struct NowView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: NowModel
    @AppStorage(AppSettings.Key.fuse, store: AppSettings.store) private var fuse = 25.0
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    @AppStorage(AppSettings.Key.priceImport, store: AppSettings.store) private var priceImport = 0.0
    @AppStorage(AppSettings.Key.priceExport, store: AppSettings.store) private var priceExport = 0.0

    init(previewReading: NowReading? = nil) {
        _model = State(initialValue: NowModel(previewReading: previewReading))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let errorText = model.errorText {
                    Banner(text: errorText, systemImage: "wifi.exclamationmark")
                } else if model.reading?.stale == true {
                    Banner(
                        text: pieterMode ? PieterCopy.stale : "Geen verse metingen van de meter.",
                        systemImage: "clock.badge.exclamationmark"
                    )
                }
                if let reading = model.reading {
                    powerCard(reading)
                    phaseCard(reading)
                    statsCard(reading)
                } else if model.errorText == nil {
                    ProgressView().padding(40)
                }
            }
            .padding()
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await model.refresh() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.poll()
        }
    }

    private func powerCard(_ reading: NowReading) -> some View {
        let isExporting = (reading.powerTotal ?? 0) < -5
        return VStack(spacing: 4) {
            Text(Format.power(reading.powerTotal))
                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isExporting ? Color.l3 : .primary)
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            if isExporting {
                Text("Teruglevering")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.l3)
            }
            Text(mood(reading))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let time = reading.time {
                Text("Bijgewerkt \(time, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private func phaseCard(_ reading: NowReading) -> some View {
        let phases = reading.phaseReadings
        let anyExporting = phases.contains { $0.isExporting }
        return Card(title: "Stroom per fase (A)") {
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 16) {
                    ForEach(phases, id: \.name) { phase in
                        PhaseBar(name: phase.name, amps: phase.amps, fuse: fuse, isExporting: phase.isExporting)
                    }
                }
                if anyExporting {
                    Label("Groene pijl (↓) betekent teruglevering op die fase.", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(Color.l3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func statsCard(_ reading: NowReading) -> some View {
        Card(title: "Overzicht") {
            VStack(spacing: 10) {
                energyStatRow("Vandaag", importKwh: reading.todayKwh, exportKwh: reading.todayExportKwh, decimals: 1)
                if let weekKwh = reading.weekKwh {
                    energyStatRow("Deze week", importKwh: weekKwh, exportKwh: reading.weekExportKwh, decimals: 1)
                }
                energyStatRow("Deze maand", importKwh: reading.monthKwh, exportKwh: reading.monthExportKwh, decimals: 0)
                if let yearKwh = reading.yearKwh {
                    energyStatRow("Dit jaar", importKwh: yearKwh, exportKwh: reading.yearExportKwh, decimals: 0)
                }
                if (reading.monthExportKwh ?? 0) > 0 {
                    StatRow(label: "Teruggeleverd vandaag", value: Format.number(reading.todayExportKwh) + " kWh")
                    StatRow(label: "Teruggeleverd deze maand", value: Format.number(reading.monthExportKwh, decimals: 0) + " kWh")
                }
                StatRow(label: "Spanning", value: [reading.voltageL1, reading.voltageL2, reading.voltageL3]
                    .map { Format.number($0, decimals: 0) }.joined(separator: " / ") + " V")
                StatRow(label: "Frequentie", value: Format.number(reading.frequency, decimals: 2) + " Hz")
                if reading.currentThdL1 != nil || reading.currentThdL2 != nil || reading.currentThdL3 != nil {
                    StatRow(label: "Stroomvervorming (THD)",
                            value: [reading.currentThdL1, reading.currentThdL2, reading.currentThdL3]
                                .map { Format.number($0, decimals: 0) }.joined(separator: " / ") + " %")
                }
            }
        }
    }

    private func energyStatRow(_ label: String, importKwh: Double, exportKwh: Double?, decimals: Int) -> some View {
        let kwhText = Format.number(importKwh, decimals: decimals) + " kWh"
        let valueText: String
        if let cost = Format.cost(importKwh: importKwh, exportKwh: exportKwh,
                                  priceImport: priceImport, priceExport: priceExport) {
            valueText = "\(kwhText) (\(Format.euro(cost)))"
        } else {
            valueText = kwhText
        }
        return StatRow(label: label, value: valueText)
    }

    private func mood(_ reading: NowReading) -> String {
        if pieterMode {
            return PieterCopy.status(for: reading, fuse: fuse)
        }
        let highest = reading.currents.dropLast().map(\.amps).max() ?? 0
        switch highest / fuse {
        case ..<0.3: return "Rustig in huis"
        case ..<0.6: return "Er draait wat"
        case ..<0.9: return "Flink aan het werk"
        default: return "Bijna aan de grens"
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

struct Banner: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
    }
}

#Preview("Nu — Afname") {
    NowView(previewReading: NowReading(
        time: .now,
        voltageL1: 232, voltageL2: 234, voltageL3: 231,
        currentL1: 8.4, currentL2: 3.2, currentL3: 11.6, currentN: 6.8,
        powerL1: 1940, powerL2: 740, powerL3: 2680, powerTotal: 5360,
        frequency: 50.01,
        currentThdL1: 4, currentThdL2: 7, currentThdL3: 3,
        todayKwh: 11.4, weekKwh: 68.2, monthKwh: 284, yearKwh: 3120,
        todayExportKwh: 2.3, weekExportKwh: 14.5, monthExportKwh: 42, yearExportKwh: 980,
        stale: false
    ))
}

#Preview("Nu — Teruglevering") {
    NowView(previewReading: NowReading(
        time: .now,
        voltageL1: 238, voltageL2: 237, voltageL3: 239,
        currentL1: 6.5, currentL2: 1.8, currentL3: 7.2, currentN: 4.1,
        powerL1: -1540, powerL2: 420, powerL3: -1710, powerTotal: -2830,
        frequency: 50.03,
        currentThdL1: 5, currentThdL2: 9, currentThdL3: 4,
        todayKwh: 4.2, weekKwh: 41.0, monthKwh: 198, yearKwh: 2890,
        todayExportKwh: 9.8, weekExportKwh: 38.4, monthExportKwh: 146, yearExportKwh: 1640,
        stale: false
    ))
}
