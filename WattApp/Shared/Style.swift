import SwiftUI

enum PhaseStyle {
    static let names = ["L1", "L2", "L3", "N"]
    static let colors: [Color] = [.l1, .l2, .l3, .neutral]

    static func color(_ name: String) -> Color {
        guard let index = names.firstIndex(of: name) else { return .gray }
        return colors[index]
    }
}

extension Color {
    static let l1 = Color(red: 0.85, green: 0.47, blue: 0.02)
    static let l2 = Color(red: 0.15, green: 0.39, blue: 0.92)
    static let l3 = Color(red: 0.02, green: 0.59, blue: 0.41)
    static let neutral = Color(red: 0.86, green: 0.15, blue: 0.15)
}

enum Format {
    static func power(_ watts: Double?) -> String {
        guard let watts else { return "–" }
        if abs(watts) >= 1000 {
            return (watts / 1000).formatted(.number.precision(.fractionLength(2))) + " kW"
        }
        return watts.formatted(.number.precision(.fractionLength(0))) + " W"
    }

    static func number(_ value: Double?, decimals: Int = 1) -> String {
        guard let value else { return "–" }
        return value.formatted(.number.precision(.fractionLength(decimals)))
    }
}

/// Droge, contextgevoelige teksten. Bewust gecentraliseerd zodat de app niet
/// langzaam verandert in een verzameling losse dad-jokes.
enum PieterCopy {
    static func status(for reading: NowReading, fuse: Double) -> String {
        if let power = reading.powerTotal, power < -200 {
            return "De meter loopt achteruit. Gratis gevoel, dure panelen."
        }

        let highest = reading.currents.dropLast().map(\.amps).max() ?? 0
        switch highest / max(fuse, 1) {
        case ..<0.12:
            return "Zo stil dat zelfs de slimme meter zich verveelt."
        case ..<0.30:
            return "Rustig. De waterkoker heeft blijkbaar vrij."
        case ..<0.55:
            return "Er draait iets. Pieter houdt het onderzoek open."
        case ..<0.80:
            return "Lekker bezig. De elektronen hebben geen pauze."
        case ..<0.95:
            return "Nog nét beschaafd. Zet niet óók de oven aan."
        default:
            return "Alles tegelijk aan? Moedig. Ook administratief."
        }
    }

    static let stale = "De meter denkt nog even na. Dat doet hij grondig."
    static let noHistory = "Nog geen verleden. Zelfs stroom moet ergens beginnen."
    static let noPeaks = "Geen pieken gevonden. Verdacht voorbeeldig."
}

struct MeasurementPlaceholder: View {
    let title: String
    let detail: String
    var systemImage = "chart.line.uptrend.xyaxis"

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(detail)
        )
        .frame(maxWidth: .infinity, minHeight: 140)
    }
}

/// Eén verticale balk voor een fase of de nulleider.
struct PhaseBar: View {
    let name: String
    let amps: Double
    let fuse: Double
    var height: CGFloat = 170
    var showsValue = true

    private var fraction: Double { min(max(amps / fuse, 0), 1) }
    private var fill: Color { amps >= fuse ? .red : PhaseStyle.color(name) }

    var body: some View {
        VStack(spacing: 8) {
            if showsValue {
                Text(Format.number(amps))
                    .font(.headline.monospacedDigit())
                    .contentTransition(.numericText())
            }
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.15))
                GeometryReader { proxy in
                    VStack {
                        Spacer(minLength: 0)
                        Capsule()
                            .fill(fill)
                            .frame(height: max(proxy.size.height * fraction, 6))
                    }
                }
            }
            .frame(height: height)
            Text(name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(Format.number(amps)) ampère")
    }
}
