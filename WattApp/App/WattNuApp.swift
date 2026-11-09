import SwiftUI

@main
struct WattNuApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 820, height: 760)
        #endif
    }
}

struct RootView: View {
    @AppStorage(AppSettings.Key.server, store: AppSettings.store) private var server = ""
    @AppStorage(AppSettings.Key.token, store: AppSettings.store) private var token = ""

    var body: some View {
        if server.isEmpty || token.isEmpty {
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
}
