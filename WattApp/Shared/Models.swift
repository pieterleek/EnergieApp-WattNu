import Foundation

struct NowReading: Codable, Sendable {
    var time: Date?
    var voltageL1: Double?
    var voltageL2: Double?
    var voltageL3: Double?
    var currentL1: Double?
    var currentL2: Double?
    var currentL3: Double?
    var currentN: Double?
    var powerL1: Double?
    var powerL2: Double?
    var powerL3: Double?
    var powerTotal: Double?
    var frequency: Double?
    var todayKwh: Double
    var monthKwh: Double
    var stale: Bool

    var currents: [(name: String, amps: Double)] {
        [("L1", currentL1 ?? 0), ("L2", currentL2 ?? 0), ("L3", currentL3 ?? 0), ("N", currentN ?? 0)]
    }
}

struct SeriesPoint: Codable, Sendable {
    var time: Date
    var currentL1: Double?
    var currentL2: Double?
    var currentL3: Double?
    var currentN: Double?
    var powerL1: Double?
    var powerL2: Double?
    var powerL3: Double?
    var powerTotal: Double?
    var voltageL1: Double?
    var voltageL2: Double?
    var voltageL3: Double?
}

struct DayUsage: Codable, Sendable, Identifiable {
    var day: Date
    var kwhTotal: Double?
    var kwhL1: Double?
    var kwhL2: Double?
    var kwhL3: Double?

    var id: Date { day }
}

struct HeatCell: Codable, Sendable, Identifiable {
    var weekday: Int
    var hour: Int
    var kwh: Double

    var id: Int { weekday * 100 + hour }
}

struct Peak: Codable, Sendable, Identifiable {
    var time: Date
    var powerTotal: Double?
    var currentL1: Double?
    var currentL2: Double?
    var currentL3: Double?
    var currentN: Double?

    var id: Date { time }
}

struct TelegramSettings: Encodable, Sendable {
    let enabled: Bool
    let phaseAlerts: Bool
    let staleAlerts: Bool
    let dailyLimitKwh: Double?
    let pieterMode: Bool
}

struct TelegramSettingsResponse: Decodable, Sendable {
    let configured: Bool
}
