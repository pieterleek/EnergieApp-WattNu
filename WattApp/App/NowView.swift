import SwiftUI

@MainActor
@Observable
final class NowModel {
    var reading: NowReading?
    var errorText: String?

    /// Ververst elke 5 seconden zolang het scherm zichtbaar is.
    func poll() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    func refresh() async {
        guard let client = APIClient.current else { return }
        do {
            let next = try await client.now()
            withAnimation(.easeInOut(duration: 0.6)) { reading = next }
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

struct NowView: View {
    @State private var model = NowModel()
    @AppStorage(AppSettings.Key.fuse, store: AppSettings.store) private var fuse = 25.0
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true

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
        .task { await model.poll() }
    }

    private func powerCard(_ reading: NowReading) -> some View {
        VStack(spacing: 4) {
            Text(Format.power(reading.powerTotal))
                .font(.system(size: 54, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
                .minimumScaleFactor(0.6)
                .lineLimit(1)
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
    }

    private func phaseCard(_ reading: NowReading) -> some View {
        Card(title: "Stroom per fase (A)") {
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(reading.currents, id: \.name) { phase in
                    PhaseBar(name: phase.name, amps: phase.amps, fuse: fuse)
                }
            }
        }
    }

    private func statsCard(_ reading: NowReading) -> some View {
        Card(title: "Overzicht") {
            VStack(spacing: 10) {
                StatRow(label: "Vandaag", value: Format.number(reading.todayKwh) + " kWh")
                StatRow(label: "Deze maand", value: Format.number(reading.monthKwh, decimals: 0) + " kWh")
                StatRow(label: "Spanning", value: [reading.voltageL1, reading.voltageL2, reading.voltageL3]
                    .map { Format.number($0, decimals: 0) }.joined(separator: " / ") + " V")
                StatRow(label: "Frequentie", value: Format.number(reading.frequency, decimals: 2) + " Hz")
            }
        }
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
