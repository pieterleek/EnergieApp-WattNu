import SwiftUI
import WidgetKit

struct SettingsView: View {
    @AppStorage(AppSettings.Key.server, store: AppSettings.store) private var server = ""
    @AppStorage(AppSettings.Key.token, store: AppSettings.store) private var token = ""
    @AppStorage(AppSettings.Key.fuse, store: AppSettings.store) private var fuse = 25.0
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    @AppStorage(AppSettings.Key.telegramEnabled, store: AppSettings.store) private var telegramEnabled = false
    @AppStorage(AppSettings.Key.telegramPhaseAlerts, store: AppSettings.store) private var telegramPhaseAlerts = true
    @AppStorage(AppSettings.Key.telegramStaleAlerts, store: AppSettings.store) private var telegramStaleAlerts = true
    @AppStorage(AppSettings.Key.telegramDailyLimitEnabled, store: AppSettings.store) private var telegramDailyLimitEnabled = false
    @AppStorage(AppSettings.Key.telegramDailyLimitKwh, store: AppSettings.store) private var telegramDailyLimitKwh = 20.0
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var telegramStatus = "Stel eerst de Telegram-bot in op de Pi."
    @State private var isTestingTelegram = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Adres, bijvoorbeeld pi.jouw-tailnet.ts.net", text: $server)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                SecureField("API-token", text: $token)
                Button {
                    Task { await test() }
                } label: {
                    if isTesting {
                        Label("Even meten…", systemImage: "hourglass")
                    } else {
                        Label("Verbinding testen", systemImage: "bolt.horizontal.circle")
                    }
                }
                .disabled(isTesting)
                if let testResult {
                    Text(testResult).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Aansluiting") {
                Stepper(value: $fuse, in: 16...80, step: 1) {
                    Text("Hoofdzekering: \(Int(fuse)) A")
                }
            }
            Section {
                Toggle("Telegram-meldingen", isOn: $telegramEnabled)
                if telegramEnabled {
                    Toggle("10 A per fase of retour", isOn: $telegramPhaseAlerts)
                    Toggle("Ontbrekende meterdata", isOn: $telegramStaleAlerts)
                    Toggle("Daglimiet", isOn: $telegramDailyLimitEnabled)
                    if telegramDailyLimitEnabled {
                        Stepper(value: $telegramDailyLimitKwh, in: 1...200, step: 1) {
                            Text("Limiet: \(Int(telegramDailyLimitKwh)) kWh per dag")
                        }
                    }
                    Button {
                        Task { await sendTestTelegram() }
                    } label: {
                        if isTestingTelegram {
                            Label("Testmelding versturen…", systemImage: "hourglass")
                        } else {
                            Label("Stuur Telegram-test", systemImage: "paperplane")
                        }
                    }
                    .disabled(isTestingTelegram)
                }
                Text(telegramStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Meldingen")
            } footer: {
                Text("De 10 A-grens geldt apart voor L1, L2 en L3. Een melding wordt pas opnieuw actief nadat de fase onder 9 A is geweest.")
            }
            Section {
                Toggle("Pieter-modus", isOn: $pieterMode)
            } footer: {
                Text("Droge opmerkingen op basis van wat er werkelijk gebeurt. Geen confetti, wel commentaar.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Instellingen")
        .onChange(of: server) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: token) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: telegramEnabled) { syncTelegramSettings() }
        .onChange(of: telegramPhaseAlerts) { syncTelegramSettings() }
        .onChange(of: telegramStaleAlerts) { syncTelegramSettings() }
        .onChange(of: telegramDailyLimitEnabled) { syncTelegramSettings() }
        .onChange(of: telegramDailyLimitKwh) { syncTelegramSettings() }
        .onChange(of: pieterMode) { syncTelegramSettings() }
        .task {
            if telegramEnabled { await syncTelegramSettingsNow() }
        }
    }

    private func test() async {
        isTesting = true
        defer { isTesting = false }
        guard let client = APIClient.current else {
            testResult = "Vul eerst het adres en het token in."
            return
        }
        do {
            let reading = try await client.now()
            testResult = "Verbonden: \(Format.power(reading.powerTotal))"
            WidgetCenter.shared.reloadAllTimelines()
            await syncTelegramSettingsNow()
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func syncTelegramSettings() {
        Task { await syncTelegramSettingsNow() }
    }

    private func syncTelegramSettingsNow() async {
        guard let client = APIClient.current else {
            telegramStatus = "Vul eerst het serveradres en API-token in."
            return
        }
        let settings = TelegramSettings(
            enabled: telegramEnabled,
            phaseAlerts: telegramPhaseAlerts,
            staleAlerts: telegramStaleAlerts,
            dailyLimitKwh: telegramDailyLimitEnabled ? telegramDailyLimitKwh : nil,
            pieterMode: pieterMode
        )
        do {
            let configured = try await client.updateTelegramSettings(settings)
            if !telegramEnabled {
                telegramStatus = "Telegram-meldingen staan uit."
            } else if configured {
                telegramStatus = "Telegram-meldingen zijn actief op de Pi."
            } else {
                telegramStatus = "Opgeslagen, maar bottoken of chat-ID ontbreekt nog op de Pi."
            }
        } catch {
            telegramStatus = "Telegram-instellingen opslaan mislukt: \(error.localizedDescription)"
        }
    }

    private func sendTestTelegram() async {
        isTestingTelegram = true
        defer { isTestingTelegram = false }
        guard let client = APIClient.current else {
            telegramStatus = "Vul eerst het serveradres en API-token in."
            return
        }
        do {
            try await client.sendTelegramTest()
            telegramStatus = "Telegram-test verstuurd."
        } catch {
            telegramStatus = "Telegram-test mislukt: \(error.localizedDescription)"
        }
    }
}
