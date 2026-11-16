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
                    GridLoadView()
                        .tabItem { Label("Net", systemImage: "point.3.connected.trianglepath.dotted") }
                    NavigationStack { SettingsView() }
                        .tabItem { Label("Instellingen", systemImage: "gearshape") }
                }
            }
        }
        .task { await PushManager.shared.refreshOnLaunch() }
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

    private var isEnabled: Bool {
        AppSettings.store.bool(forKey: AppSettings.Key.pushEnabled)
    }

    private var storedToken: String? {
        AppSettings.store.string(forKey: AppSettings.Key.pushToken)
    }

    /// Apparaattokens kunnen wisselen; daarom bij elke start opnieuw aanmelden.
    func refreshOnLaunch() async {
        guard isEnabled else { return }
        registerWithSystem()
    }

    func enable() async {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            guard granted else {
                status = "Meldingen zijn geweigerd. Sta ze toe in de systeeminstellingen en probeer opnieuw."
                AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
                return
            }
            status = "Aanmelden bij Apple…"
            registerWithSystem()
        } catch {
            status = "Toestemming vragen mislukt: \(error.localizedDescription)"
            AppSettings.store.set(false, forKey: AppSettings.Key.pushEnabled)
        }
    }

    func disable() async {
        guard let token = storedToken else { return }
        AppSettings.store.removeObject(forKey: AppSettings.Key.pushToken)
        #if os(iOS)
        UIApplication.shared.unregisterForRemoteNotifications()
        #else
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
        do {
            try await APIClient.current?.removeDevice(token: token)
            status = "Pushmeldingen staan uit op dit apparaat."
        } catch {
            status = "Uitgezet, maar afmelden bij de Pi mislukte: \(error.localizedDescription)"
        }
    }

    func didRegister(deviceToken: Data) async {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        guard isEnabled else { return }
        guard let client = APIClient.current else {
            status = "Vul eerst het serveradres en API-token in."
            return
        }
        let previous = storedToken
        do {
            let response = try await client.registerDevice(DeviceRegistration(
                token: token, platform: Self.platform, environment: Self.environment
            ))
            AppSettings.store.set(token, forKey: AppSettings.Key.pushToken)
            if let previous, previous != token {
                try? await client.removeDevice(token: previous)
            }
            status = response.configured
                ? "Dit apparaat ontvangt pushmeldingen."
                : "Aangemeld, maar de APNs-sleutel ontbreekt nog op de Pi."
        } catch {
            status = "Aanmelden bij de Pi mislukt: \(error.localizedDescription)"
        }
    }

    func didFail(_ error: Error) {
        status = "Aanmelden bij Apple mislukt: \(error.localizedDescription)"
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

    /// Een build uit Xcode praat met de sandbox van Apple, TestFlight en de
    /// App Store met productie. Een token werkt alleen in zijn eigen omgeving.
    private static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
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
