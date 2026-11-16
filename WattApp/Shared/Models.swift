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
    var currentThdL1: Double?
    var currentThdL2: Double?
    var currentThdL3: Double?
    var todayKwh: Double
    var monthKwh: Double
    var todayExportKwh: Double?
    var monthExportKwh: Double?
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
    var kwhExport: Double?
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

struct GridLoadPoint: Codable, Sendable, Identifiable {
    var time: Date
    var loadMw: Double

    var id: Date { time }
}

struct GridLoadResponse: Codable, Sendable {
    var generatedAt: Date
    var intervalMinutes: Int
    var source: String
    var license: String
    var stale: Bool
    var points: [GridLoadPoint]
}

/// Sluipverbruik van één nacht.
struct BaseloadDay: Codable, Sendable, Identifiable {
    var day: Date
    var watts: Double

    var id: Date { day }
}

/// Deze week en maand tot nu toe, naast hetzelfde stuk van de vorige periode.
struct Comparison: Codable, Sendable {
    var weekKwh: Double?
    var weekExportKwh: Double?
    var previousWeekKwh: Double?
    var previousWeekExportKwh: Double?
    var monthKwh: Double?
    var monthExportKwh: Double?
    var previousMonthKwh: Double?
    var previousMonthExportKwh: Double?
    var lastYearMonthKwh: Double?
    var lastYearMonthExportKwh: Double?
}

/// Voorkeuren die op de server staan en dus op elk apparaat gelijk zijn.
struct ServerSettings: Codable, Sendable, Equatable {
    var enabled = false
    var telegramEnabled = true
    var pushEnabled = true
    var phaseAlerts = true
    var phaseLimitAmps = 14.0
    var phaseHoldSeconds = 60
    var staleAlerts = true
    var dailyLimitKwh: Double?
    var voltageAlerts = false
    var voltageMin = 207.0
    var voltageMax = 253.0
    var frequencyAlerts = false
    var pieterMode = true
    var priceImport: Double?
    var priceExport: Double?
}

struct NotificationChannels: Codable, Sendable, Equatable {
    var telegram = false
    var push = false
    var pushDevices = 0
}

struct SettingsEnvelope: Codable, Sendable {
    var settings: ServerSettings
    var channels: NotificationChannels
}

struct DeviceRegistration: Encodable, Sendable {
    let token: String
    let platform: String
    let environment: String
}

struct DeviceRegistrationResponse: Decodable, Sendable {
    let registered: Bool
    let configured: Bool
}
