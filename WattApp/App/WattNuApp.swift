import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@main
struct WattNuApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        AppSettings.migrateTokenToKeychain()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 760)
        #endif
    }
}

@MainActor
struct RootView: View {
    @AppStorage(AppSettings.Key.server, store: AppSettings.store) private var server = ""
    @AppStorage(AppSettings.Key.hasToken, store: AppSettings.store) private var hasToken = false

    var body: some View {
        Group {
            if server.isEmpty || !hasToken {
                NavigationStack { SettingsView() }
            } else {
                TabView {
                    NowView()
                        .tabItem { Label("Nu", systemImage: "bolt.fill") }
                    HistoryView()
                        .tabItem { Label("Verloop", systemImage: "chart.xyaxis.line") }
                    UsageView()
                        .tabItem { Label("Gebruik", systemImage: "calendar") }
                    CostsView()
                        .tabItem { Label("Kosten", systemImage: "eurosign.circle") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Instellingen", systemImage: "gearshape") }
                }
            }
        }
        .task {
            await syncSharedSettings()
            await PushManager.shared.refreshOnLaunch()
        }
    }

    private func syncSharedSettings() async {
        guard let client = APIClient.current,
              let envelope = try? await client.settings() else { return }
        AppSettings.cachePrices(from: envelope.settings)
        AppSettings.store.set(envelope.settings.pieterMode, forKey: AppSettings.Key.pieterMode)
    }
}

// MARK: - Pushmeldingen

/// Meldt dit apparaat aan bij Apple en geeft het apparaattoken door aan de Pi.
/// De Pi verstuurt de meldingen; de app hoeft daarvoor niet open te staan.
@MainActor
@Observable
final class PushManager {
    static let shared = PushManager()

    var status = ""
    var registrationVersion = 0

    private var isEnabled: Bool {
        AppSettings.store.bool(forKey: AppSettings.Key.pushEnabled)
    }

    private var storedToken: String? {
        AppSettings.store.string(forKey: AppSettings.Key.pushToken)
    }

    /// Apparaattokens kunnen wisselen; daarom bij elke start opnieuw aanmelden.
    func refreshOnLaunch() async {
        guard isEnabled else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if settings.authorizationStatus == .denied {
            status = "Meldingen staan uit in de systeeminstellingen. Zet ze daar aan om pushmeldingen te ontvangen."
            return
        }
        registerWithSystem()
    }

    func enable() async {
        let currentSettings = await UNUserNotificationCenter.current().notificationSettings()
        if currentSettings.authorizationStatus == .denied {
            status = "Meldingen zijn geweigerd. Sta ze toe in Instellingen > Meldingen > WattNu en probeer opnieuw."
            AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
            registrationVersion += 1
            return
        }
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            guard granted else {
                status = "Meldingen zijn geweigerd. Sta ze toe in de systeeminstellingen en probeer opnieuw."
                AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
                registrationVersion += 1
                return
            }
            status = "Aanmelden bij Apple…"
            registerWithSystem()
        } catch {
            status = "Toestemming vragen mislukt: \(error.localizedDescription)"
            AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
            registrationVersion += 1
        }
    }

    func disable() async {
        let token = storedToken
        AppSettings.store.removeObject(forKey: AppSettings.Key.pushToken)
        #if os(iOS)
        UIApplication.shared.unregisterForRemoteNotifications()
        #else
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
        guard let token else {
            status = "Pushmeldingen staan uit op dit apparaat."
            registrationVersion += 1
            return
        }
        do {
            try await APIClient.current?.removeDevice(token: token)
            status = "Pushmeldingen staan uit op dit apparaat."
        } catch {
            status = "Uitgezet, maar afmelden bij de Pi mislukte: \(error.localizedDescription)"
        }
        registrationVersion += 1
    }

    func didRegister(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard isEnabled else { return }
        guard let client = APIClient.current else {
            status = "Vul eerst het serveradres en API-token in."
            registrationVersion += 1
            return
        }
        let previous = storedToken
        do {
            let response = try await client.registerDevice(DeviceRegistration(
                token: token,
                platform: Self.platform,
                environment: Self.environment,
                bundleId: Bundle.main.bundleIdentifier
            ))
            AppSettings.store.set(token, forKey: AppSettings.Key.pushToken)
            if let previous, previous != token {
                try? await client.removeDevice(token: previous)
            }
            if let warning = response.warning, !warning.isEmpty {
                status = "Aangemeld, maar: \(warning)"
            } else {
                status = response.configured
                    ? "Dit apparaat ontvangt pushmeldingen (\(Self.environment))."
                    : "Aangemeld, maar de APNs-sleutel ontbreekt nog op de Pi."
            }
        } catch {
            status = "Aanmelden bij de Pi mislukt: \(error.localizedDescription)"
        }
        registrationVersion += 1
    }

    func didFail(_ error: Error) {
        let message = error.localizedDescription
        if message.localizedCaseInsensitiveContains("aps-environment") {
            status = "Apple-push ontbreekt in de app-signing (aps-environment). Controleer Push Notifications in Xcode (vereist betaald Apple Developer-account)."
        } else {
            status = "Aanmelden bij Apple mislukt: \(message)"
        }
        AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
        registrationVersion += 1
    }

    private func registerWithSystem() {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    private static var platform: String {
        #if os(iOS)
        return "ios"
        #else
        return "macos"
        #endif
    }

    /// Leest de werkelijke aps-environment uit het provisioning-profiel op iOS
    /// (voorkomt sandbox/productie-mismatch bij Release-builds uit Xcode) en valt
    /// anders terug op DEBUG/Release.
    private static var environment: String {
        if let provisioning = provisioningApsEnvironment() {
            return provisioning == "production" ? "production" : "sandbox"
        }
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    private static func provisioningApsEnvironment() -> String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .isoLatin1),
              let start = content.range(of: "<plist")?.lowerBound,
              let end = content.range(of: "</plist>")?.upperBound,
              let plistData = String(content[start..<end]).data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return nil
        }
        return aps
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in PushManager.shared.didFail(error) }
    }

    /// Toon een melding ook als de app op dat moment open is.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in PushManager.shared.didFail(error) }
    }

    /// Toon een melding ook als de app op dat moment open is.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
#endif
