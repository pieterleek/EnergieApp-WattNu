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
    var weekKwh: Double?
    var monthKwh: Double
    var yearKwh: Double?
    var todayExportKwh: Double?
    var weekExportKwh: Double?
    var monthExportKwh: Double?
    var yearExportKwh: Double?
    var stale: Bool

    var currents: [(name: String, amps: Double)] {
        [("L1", currentL1 ?? 0), ("L2", currentL2 ?? 0), ("L3", currentL3 ?? 0), ("N", currentN ?? 0)]
    }

    var phaseReadings: [(name: String, amps: Double, isExporting: Bool)] {
        [
            ("L1", currentL1 ?? 0, (powerL1 ?? 0) < -5),
            ("L2", currentL2 ?? 0, (powerL2 ?? 0) < -5),
            ("L3", currentL3 ?? 0, (powerL3 ?? 0) < -5),
            ("N", currentN ?? 0, false),
        ]
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

enum CostPeriod: String, CaseIterable, Identifiable, Codable, Sendable {
    case day
    case week
    case month
    case year

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Dag"
        case .week: return "Week"
        case .month: return "Maand"
        case .year: return "Jaar"
        }
    }

    var perLabel: String {
        switch self {
        case .day: return "per dag"
        case .week: return "per week"
        case .month: return "per maand"
        case .year: return "per jaar"
        }
    }

    var defaultCount: Int {
        switch self {
        case .day: return 30
        case .week: return 26
        case .month: return 12
        case .year: return 10
        }
    }
}

struct CostPeriodSummary: Codable, Sendable {
    var kwhImport: Double
    var kwhImportPeak: Double?
    var kwhImportOffpeak: Double?
    var kwhExport: Double
    var daysCount: Int?
    var cost: Double?
}

struct CostSummary: Codable, Sendable {
    var day: CostPeriodSummary
    var week: CostPeriodSummary
    var month: CostPeriodSummary
    var year: CostPeriodSummary
}

struct CostEntry: Codable, Sendable, Identifiable {
    var start: Date
    var localDate: String
    var kwhImport: Double
    var kwhImportPeak: Double?
    var kwhImportOffpeak: Double?
    var kwhExport: Double
    var daysCount: Int?
    var cost: Double?

    var id: String { localDate }
}

struct CostsResponse: Codable, Sendable {
    var period: CostPeriod
    var priceImport: Double?
    var priceImportOffpeak: Double?
    var priceExport: Double?
    var fixedDailyCost: Double?
    var summary: CostSummary
    var entries: [CostEntry]
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
    var priceImportOffpeak: Double?
    var priceExport: Double?
    var fixedDailyCost: Double?
}

struct NotificationChannels: Codable, Sendable, Equatable {
    var telegram = false
    var push = false
    var pushDevices = 0
    var pushError: String?
    var apnsBundleId: String?
}

struct SettingsEnvelope: Codable, Sendable {
    var settings: ServerSettings
    var channels: NotificationChannels
}

struct DeviceRegistration: Encodable, Sendable {
    let token: String
    let platform: String
    let environment: String
    let bundleId: String?
}

struct DeviceRegistrationResponse: Decodable, Sendable {
    let registered: Bool
    let configured: Bool
    let warning: String?
}
