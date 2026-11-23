import SwiftUI
import WidgetKit

@MainActor
struct SettingsView: View {
    @AppStorage(AppSettings.Key.server, store: AppSettings.store) private var server = ""
    @AppStorage(AppSettings.Key.fuse, store: AppSettings.store) private var fuse = 25.0
    @AppStorage(AppSettings.Key.pieterMode, store: AppSettings.store) private var pieterMode = true
    @AppStorage(AppSettings.Key.pushEnabled, store: AppSettings.store) private var pushEnabled = false

    @State private var token = AppSettings.token
    @State private var testResult: String?
    @State private var isTesting = false

    /// Gedeelde voorkeuren. De server is de bron van waarheid: we halen ze op
    /// bij het openen en sturen elke wijziging kort daarna terug.
    @State private var remote: ServerSettings
    @State private var lastSynced: ServerSettings?
    @State private var channels: NotificationChannels
    @State private var syncStatus: String
    @State private var testStatus: String?
    @State private var testingChannel: String?
    @FocusState private var isNumericFieldFocused: Bool
    private let isPreview: Bool

    init(previewSettings: ServerSettings? = nil, previewChannels: NotificationChannels? = nil) {
        _remote = State(initialValue: previewSettings ?? ServerSettings())
        _lastSynced = State(initialValue: previewSettings)
        _channels = State(initialValue: previewChannels ?? NotificationChannels())
        _syncStatus = State(initialValue: previewSettings != nil ? "Opgeslagen op de Pi." : "Instellingen ophalen…")
        self.isPreview = previewSettings != nil
    }

    private var push: PushManager { PushManager.shared }
    private var isLoaded: Bool { lastSynced != nil }
    /// Vaste keuzes, plus de huidige waarde als die via de API anders is gezet.
    private var holdChoices: [Int] {
        Set([0, 15, 30, 60, 120, 300, remote.phaseHoldSeconds]).sorted()
    }

    var body: some View {
        Form {
            serverSection
            Section("Aansluiting") {
                Stepper(value: $fuse, in: 16...80, step: 1) {
                    Text("Hoofdzekering: \(Int(fuse)) A")
                }
            }
            if isLoaded {
                alertSection
                channelSection
                priceSection
            } else {
                Section("Meldingen en tarieven") {
                    Text(syncStatus).font(.footnote).foregroundStyle(.secondary)
                    Button("Opnieuw ophalen") { Task { await loadRemote() } }
                }
            }
            Section {
                Toggle("Pieter-modus", isOn: $pieterMode)
            } footer: {
                Text("Droge opmerkingen op basis van wat er werkelijk gebeurt. Geen confetti, wel commentaar.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Instellingen")
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Gereed") { isNumericFieldFocused = false }
            }
        }
        #endif
        .onChange(of: server) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: token) {
            AppSettings.setToken(token)
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: fuse) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: pieterMode) { remote.pieterMode = pieterMode }
        .onChange(of: pushEnabled) {
            Task {
                if pushEnabled {
                    if isLoaded && !remote.pushEnabled {
                        remote.pushEnabled = true
                    }
                    await push.enable()
                } else {
                    await push.disable()
                }
            }
        }
        .onChange(of: push.registrationVersion) {
            Task { await refreshChannels() }
        }
        .task { await loadRemote() }
        // Wacht even na de laatste wijziging, zodat een stepper niet bij elke
        // tik een verzoek stuurt.
        .task(id: remote) {
            guard isLoaded, remote != lastSynced else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await saveRemote(remote)
        }
    }

    // MARK: Secties

    private var serverSection: some View {
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
    }

    private var alertSection: some View {
        Section {
            Toggle("Meldingen", isOn: $remote.enabled)
            if remote.enabled {
                Toggle("Hoge stroom per fase", isOn: $remote.phaseAlerts)
                if remote.phaseAlerts {
                    Stepper(value: $remote.phaseLimitAmps, in: 6...80, step: 1) {
                        Text("Grens: \(Int(remote.phaseLimitAmps)) A")
                    }
                    Picker("Wachttijd", selection: $remote.phaseHoldSeconds) {
                        ForEach(holdChoices, id: \.self) { seconds in
                            Text(holdLabel(seconds)).tag(seconds)
                        }
                    }
                }
                Toggle("Ontbrekende meterdata", isOn: $remote.staleAlerts)
                Toggle("Daglimiet", isOn: dailyLimitEnabled)
                if let limit = remote.dailyLimitKwh {
                    Stepper(value: dailyLimit, in: 1...200, step: 1) {
                        Text("Limiet: \(Int(limit)) kWh per dag")
                    }
                }
                Toggle("Spanning buiten bereik", isOn: $remote.voltageAlerts)
                if remote.voltageAlerts {
                    Stepper(value: $remote.voltageMin, in: 180...225, step: 1) {
                        Text("Ondergrens: \(Int(remote.voltageMin)) V")
                    }
                    Stepper(value: $remote.voltageMax, in: 235...265, step: 1) {
                        Text("Bovengrens: \(Int(remote.voltageMax)) V")
                    }
                }
                Toggle("Netfrequentie buiten 49,8–50,2 Hz", isOn: $remote.frequencyAlerts)
            }
            Text(syncStatus).font(.footnote).foregroundStyle(.secondary)
        } header: {
            Text("Meldingen")
        } footer: {
            Text("Deze instellingen staan op de Pi en gelden voor al je apparaten. De stroomgrens geldt apart voor L1, L2 en L3, voor afname en teruglevering; een alarm wordt opnieuw actief zodra de stroom 1 A onder de grens is geweest.")
        }
    }

    private var channelSection: some View {
        Section {
            Toggle("Telegram", isOn: $remote.telegramEnabled)
            if !channels.telegram {
                Text("Bottoken of chat-ID ontbreekt nog op de Pi.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Toggle("Apple-push (alle apparaten)", isOn: $remote.pushEnabled)
            Toggle("Pushmeldingen op dit apparaat", isOn: $pushEnabled)
            if !push.status.isEmpty {
                Text(push.status).font(.footnote).foregroundStyle(.secondary)
            }
            if !channels.push {
                Text(channels.pushError ?? "De APNs-sleutel ontbreekt nog op de Pi.")
                    .font(.footnote).foregroundStyle(.orange)
            } else {
                Text("Aangemelde apparaten: \(channels.pushDevices)")
                    .font(.footnote).foregroundStyle(.secondary)
                if let serverBundle = channels.apnsBundleId,
                   let appBundle = Bundle.main.bundleIdentifier,
                   serverBundle != appBundle {
                    Text("Let op: app Bundle-ID (\(appBundle)) wijkt af van APNS_BUNDLE_ID op de Pi (\(serverBundle)).")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            if !remote.enabled && (pushEnabled || remote.telegramEnabled) {
                Text("Let op: zet hierboven eerst 'Meldingen' aan, anders verstuurt de Pi alleen testmeldingen en geen echte alarmen.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            testButton("Stuur Telegram-test", channel: "telegram", systemImage: "paperplane")
                .disabled(!channels.telegram || testingChannel != nil)
            testButton("Stuur pushtest", channel: "push", systemImage: "bell.badge")
                .disabled(!channels.push || testingChannel != nil)
            if let testStatus {
                Text(testStatus).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Kanalen")
        } footer: {
            Text("Een pushtest gaat naar alle aangemelde apparaten. Meldingen komen ook aan als de app dicht is.")
        }
    }

    private var priceSection: some View {
        Section {
            priceField("Afname / piek (€/kWh)", placeholder: "bijv. 0,28", value: $remote.priceImport)
            priceField("Daltarief (€/kWh)", placeholder: "optioneel", value: $remote.priceImportOffpeak)
            priceField("Teruglevering (€/kWh)", placeholder: "optioneel", value: $remote.priceExport)
            priceField("Vaste kosten (€/dag)", placeholder: "optioneel", value: $remote.fixedDailyCost, allowNegative: true)
        } header: {
            Text("Tarieven")
        } footer: {
            Text("Vul alleen Afname in voor enkeltarief, of voeg een Daltarief toe voor piek/dal (ma–vr 23:00–07:00 en weekend). Vaste kosten mag ook negatief zijn (bijv. door vermindering energiebelasting). Je kunt dit ook direct op de tab Kosten aanpassen.")
        }
    }

    private func priceField(
        _ label: String,
        placeholder: String,
        value: Binding<Double?>,
        allowNegative: Bool = false
    ) -> some View {
        LabeledContent(label) {
            TextField(placeholder, value: value, format: .number.precision(.fractionLength(0...4)))
                .multilineTextAlignment(.trailing)
                .focused($isNumericFieldFocused)
                #if os(iOS)
                .keyboardType(allowNegative ? .numbersAndPunctuation : .decimalPad)
                #endif
        }
    }

    private func testButton(_ title: String, channel: String, systemImage: String) -> some View {
        Button {
            Task { await sendTest(channel: channel) }
        } label: {
            Label(testingChannel == channel ? "Versturen…" : title, systemImage: systemImage)
        }
    }

    private func holdLabel(_ seconds: Int) -> String {
        switch seconds {
        case 0: return "Direct"
        case ..<60: return "\(seconds) seconden"
        case 60: return "1 minuut"
        default: return "\(seconds / 60) minuten"
        }
    }

    private var dailyLimitEnabled: Binding<Bool> {
        Binding(
            get: { remote.dailyLimitKwh != nil },
            set: { remote.dailyLimitKwh = $0 ? 20 : nil }
        )
    }

    private var dailyLimit: Binding<Double> {
        Binding(
            get: { remote.dailyLimitKwh ?? 20 },
            set: { remote.dailyLimitKwh = $0 }
        )
    }

    // MARK: Acties

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
            AppSettings.cacheReading(reading)
            WidgetCenter.shared.reloadAllTimelines()
            await loadRemote()
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func loadRemote() async {
        guard !isPreview else { return }
        guard let client = APIClient.current else {
            syncStatus = "Vul eerst het serveradres en API-token in."
            return
        }
        do {
            let envelope = try await client.settings()
            lastSynced = envelope.settings
            remote = envelope.settings
            channels = envelope.channels
            pieterMode = envelope.settings.pieterMode
            AppSettings.cachePrices(from: envelope.settings)
            syncStatus = "Opgeslagen op de Pi."
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            syncStatus = "Instellingen ophalen mislukt: \(error.localizedDescription)"
        }
    }

    private func saveRemote(_ settings: ServerSettings) async {
        guard !isPreview, let client = APIClient.current else { return }
        do {
            let envelope = try await client.updateSettings(settings)
            lastSynced = settings
            channels = envelope.channels
            AppSettings.cachePrices(from: settings)
            syncStatus = "Opgeslagen op de Pi."
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            syncStatus = "Opslaan mislukt: \(error.localizedDescription)"
        }
    }

    private func refreshChannels() async {
        guard let envelope = try? await APIClient.current?.settings() else { return }
        channels = envelope.channels
    }

    private func sendTest(channel: String) async {
        testingChannel = channel
        defer { testingChannel = nil }
        guard let client = APIClient.current else { return }
        do {
            try await client.sendTestNotification(channel: channel)
            testStatus = "Testmelding verstuurd."
        } catch {
            testStatus = "Test mislukt: \(error.localizedDescription)"
        }
    }
}

#Preview("Instellingen") {
    NavigationStack {
        SettingsView(
            previewSettings: ServerSettings(
                enabled: true,
                telegramEnabled: true,
                pushEnabled: true,
                phaseAlerts: true,
                phaseLimitAmps: 16,
                phaseHoldSeconds: 60,
                staleAlerts: true,
                dailyLimitKwh: 20,
                voltageAlerts: false,
                frequencyAlerts: false,
                pieterMode: true,
                priceImport: 0.30,
                priceImportOffpeak: 0.24,
                priceExport: 0.07,
                fixedDailyCost: 0.85
            ),
            previewChannels: NotificationChannels(
                telegram: true,
                push: true,
                pushDevices: 2,
                apnsBundleId: "io.qman.WattNu"
            )
        )
    }
}
