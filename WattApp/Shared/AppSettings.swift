import Foundation

/// Instellingen die de app en de widget delen via de App Group.
enum AppSettings {
    static let suiteName = "group.io.qman.wattnu"
    static let store = UserDefaults(suiteName: suiteName) ?? .standard

    enum Key {
        static let server = "server"
        static let token = "token"
        static let fuse = "fuse"
        static let pieterMode = "pieterMode"
        static let telegramEnabled = "telegramEnabled"
        static let telegramPhaseAlerts = "telegramPhaseAlerts"
        static let telegramStaleAlerts = "telegramStaleAlerts"
        static let telegramDailyLimitEnabled = "telegramDailyLimitEnabled"
        static let telegramDailyLimitKwh = "telegramDailyLimitKwh"
    }

    static var token: String {
        store.string(forKey: Key.token)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static var fuseAmps: Double {
        let value = store.double(forKey: Key.fuse)
        return value > 0 ? value : 25
    }

    /// Pieter-modus staat standaard aan, maar blijft optioneel voor serieuze momenten.
    static var pieterModeEnabled: Bool {
        guard store.object(forKey: Key.pieterMode) != nil else { return true }
        return store.bool(forKey: Key.pieterMode)
    }

    static var telegramEnabled: Bool { store.bool(forKey: Key.telegramEnabled) }

    static var telegramPhaseAlerts: Bool {
        bool(for: Key.telegramPhaseAlerts, default: true)
    }

    static var telegramStaleAlerts: Bool {
        bool(for: Key.telegramStaleAlerts, default: true)
    }

    static var telegramDailyLimitKwh: Double? {
        guard store.bool(forKey: Key.telegramDailyLimitEnabled) else { return nil }
        let value = store.double(forKey: Key.telegramDailyLimitKwh)
        return value > 0 ? value : 20
    }

    static var serverURL: URL? {
        var text = store.string(forKey: Key.server)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    private static func bool(for key: String, default defaultValue: Bool) -> Bool {
        guard store.object(forKey: key) != nil else { return defaultValue }
        return store.bool(forKey: key)
    }
}
