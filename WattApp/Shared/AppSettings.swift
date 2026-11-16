import Foundation
import Security

/// Instellingen die de app en de widget delen via de App Group.
/// Het API-token staat in de Keychain; de rest is niet geheim.
enum AppSettings {
    static let suiteName = "group.io.qman.wattnu"
    static let store = UserDefaults(suiteName: suiteName) ?? .standard

    enum Key {
        static let server = "server"
        /// Oude opslagplek van het token; wordt bij de eerste start leeggemaakt.
        static let legacyToken = "token"
        /// Niet-geheime vlag, zodat de interface kan reageren op een ingesteld token.
        static let hasToken = "hasToken"
        static let fuse = "fuse"
        static let pieterMode = "pieterMode"
        static let priceImport = "priceImport"
        static let priceExport = "priceExport"
        static let pushEnabled = "pushEnabled"
        static let pushToken = "pushToken"
        static let cachedReading = "cachedReading"
    }

    // MARK: Token

    static var token: String {
        if let stored = Keychain.read(), !stored.isEmpty { return stored }
        return legacyToken
    }

    static func setToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete()
            store.removeObject(forKey: Key.legacyToken)
        } else if Keychain.write(trimmed) {
            store.removeObject(forKey: Key.legacyToken)
        } else {
            // Zonder werkende Keychain (bijvoorbeeld een ongesigneerde build)
            // blijft de app bruikbaar met de oude opslag.
            store.set(trimmed, forKey: Key.legacyToken)
        }
        store.set(!trimmed.isEmpty, forKey: Key.hasToken)
    }

    /// Verplaatst een token uit de oude voorkeuren eenmalig naar de Keychain.
    static func migrateTokenToKeychain() {
        let legacy = legacyToken
        if !legacy.isEmpty, Keychain.write(legacy), Keychain.read() == legacy {
            store.removeObject(forKey: Key.legacyToken)
        }
        store.set(!token.isEmpty, forKey: Key.hasToken)
    }

    private static var legacyToken: String {
        store.string(forKey: Key.legacyToken)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Overige instellingen

    static var fuseAmps: Double {
        let value = store.double(forKey: Key.fuse)
        return value > 0 ? value : 25
    }

    /// Pieter-modus staat standaard aan, maar blijft optioneel voor serieuze momenten.
    static var pieterModeEnabled: Bool {
        guard store.object(forKey: Key.pieterMode) != nil else { return true }
        return store.bool(forKey: Key.pieterMode)
    }

    static var serverURL: URL? {
        var text = store.string(forKey: Key.server)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text)
    }

    /// Tarieven komen van de server; hier staat een kopie voor snelle weergave.
    /// 0 betekent: niet ingesteld.
    static func cachePrices(from settings: ServerSettings) {
        store.set(settings.priceImport ?? 0, forKey: Key.priceImport)
        store.set(settings.priceExport ?? 0, forKey: Key.priceExport)
    }

    // MARK: Laatste meting, voor de widget zonder verbinding

    static func cacheReading(_ reading: NowReading) {
        guard let data = try? JSONEncoder().encode(reading) else { return }
        store.set(data, forKey: Key.cachedReading)
    }

    static var cachedReading: NowReading? {
        guard let data = store.data(forKey: Key.cachedReading) else { return nil }
        return try? JSONDecoder().decode(NowReading.self, from: data)
    }
}

/// Eén Keychain-item voor het API-token. App en widget delen het via de
/// gezamenlijke `keychain-access-groups`-entitlement.
enum Keychain {
    private static let service = "io.qman.wattnu.api-token"
    private static let account = "default"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func write(_ value: String) -> Bool {
        let data = Data(value.utf8)
        // Na de eerste ontgrendeling leesbaar, zodat de widget ook op een
        // vergrendeld toestel kan verversen.
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        let item = baseQuery.merging(attributes) { _, new in new }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
