import Charts
import SwiftUI
import UniformTypeIdentifiers

struct CostsView: View {
    @State private var period: CostPeriod
    @State private var response: CostsResponse?
    @State private var errorText: String?
    @State private var isLoading = false
    @State private var selectedDate: Date?

    @AppStorage(AppSettings.Key.priceImport, store: AppSettings.store) private var priceImport = 0.0
    @AppStorage(AppSettings.Key.priceImportOffpeak, store: AppSettings.store) private var priceImportOffpeak = 0.0
    @AppStorage(AppSettings.Key.priceExport, store: AppSettings.store) private var priceExport = 0.0
    @AppStorage(AppSettings.Key.fixedDailyCost, store: AppSettings.store) private var fixedDailyCost = 0.0

    @State private var importText = ""
    @State private var offpeakText = ""
    @State private var exportText = ""
    @State private var fixedText = ""
    @State private var showAdvancedTariffs = false
    @State private var saveStatus: String?
    @State private var pendingSaveToken = 0
    @State private var isSyncingText = false
    @FocusState private var focusedField: PriceField?
    private let isPreview: Bool

    init(previewResponse: CostsResponse? = nil) {
        _period = State(initialValue: previewResponse?.period ?? .day)
        _response = State(initialValue: previewResponse)
        self.isPreview = previewResponse != nil
    }

    private enum PriceField {
        case importPrice
        case offpeakPrice
        case exportPrice
        case fixedCost
    }

    private var hasPrice: Bool { priceImport > 0 }
    private var hasOffpeak: Bool { priceImportOffpeak > 0 }
    private var entries: [CostEntry] { response?.entries ?? [] }
    private var hasAdvancedValues: Bool {
        priceImportOffpeak > 0 || priceExport > 0 || fixedDailyCost != 0
    }

    private var selectedEntry: CostEntry? {
        guard let selectedDate, !entries.isEmpty else { return nil }
        return entries.min {
            abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    tariffCard

                    if let errorText {
                        Banner(text: errorText, systemImage: "wifi.exclamationmark")
                    }

                    if let summary = response?.summary {
                        summaryGrid(summary)
                    }

                    Picker("Periode", selection: $period) {
                        ForEach(CostPeriod.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if isLoading && response == nil {
                        ProgressView("Verbruik en kosten ophalen…")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else if entries.isEmpty {
                        MeasurementPlaceholder(
                            title: "Nog geen gegevens",
                            detail: "Zodra er metingen zijn opgeslagen verschijnt hier het overzicht \(period.perLabel).",
                            systemImage: "eurosign.circle"
                        )
                    } else {
                        Card(title: hasPrice ? "Kosten \(period.perLabel)" : "Verbruik \(period.perLabel)") {
                            periodChart
                        }
                        Card(title: "Overzicht \(period.perLabel)") {
                            periodList
                        }
                    }
                }
                .padding()
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Kosten")
            .toolbar {
                if !entries.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(
                            item: csvExport,
                            preview: SharePreview("WattNu kosten (\(period.label.lowercased()))", image: Image(systemName: "tablecells"))
                        ) {
                            Label("Exporteer CSV", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                #if os(iOS)
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Gereed") { focusedField = nil }
                }
                #endif
            }
        }
        .refreshable { await load() }
        .onAppear {
            if isPreview, let preview = response {
                if let p = preview.priceImport { priceImport = p }
                if let p = preview.priceImportOffpeak { priceImportOffpeak = p }
                if let p = preview.priceExport { priceExport = p }
                if let f = preview.fixedDailyCost { fixedDailyCost = f }
            }
            syncTextFromStorage()
            if hasAdvancedValues { showAdvancedTariffs = true }
        }
        .onChange(of: priceImport) {
            if focusedField != .importPrice { syncTextFromStorage() }
        }
        .onChange(of: priceImportOffpeak) {
            if focusedField != .offpeakPrice { syncTextFromStorage() }
        }
        .onChange(of: priceExport) {
            if focusedField != .exportPrice { syncTextFromStorage() }
        }
        .onChange(of: fixedDailyCost) {
            if focusedField != .fixedCost { syncTextFromStorage() }
        }
        .task(id: period) {
            selectedDate = nil
            await load()
        }
        .task(id: pendingSaveToken) {
            guard pendingSaveToken > 0 else { return }
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await saveTariffsToServer()
        }
    }

    // MARK: Tariefkaart

    private var tariffCard: some View {
        Card(title: "Prijs per kWh") {
            VStack(alignment: .leading, spacing: 12) {
                tariffRow(
                    label: hasOffpeak ? "Normaal / piek (€/kWh)" : "Afname (€/kWh)",
                    placeholder: "bijv. 0,28",
                    text: $importText,
                    field: .importPrice,
                    onChange: handleImportTextChange
                )

                DisclosureGroup("Uitgebreide tarieven (dal, teruglevering, vastrecht)", isExpanded: $showAdvancedTariffs) {
                    VStack(alignment: .leading, spacing: 10) {
                        tariffRow(
                            label: "Daltarief (€/kWh)",
                            placeholder: "optioneel",
                            text: $offpeakText,
                            field: .offpeakPrice,
                            onChange: handleOffpeakTextChange
                        )
                        Text("Daluren: ma–vr 23:00–07:00 en het hele weekend.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        tariffRow(
                            label: "Teruglevering (€/kWh)",
                            placeholder: "optioneel",
                            text: $exportText,
                            field: .exportPrice,
                            onChange: handleExportTextChange
                        )
                        tariffRow(
                            label: "Vaste kosten (€/dag)",
                            placeholder: "bijv. 0,85",
                            text: $fixedText,
                            field: .fixedCost,
                            allowNegative: true,
                            onChange: handleFixedTextChange
                        )
                        Text("Vastrecht per dag (mag ook negatief zijn door vermindering energiebelasting).")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let saveStatus {
                    Text(saveStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !hasPrice {
                    Text("Vul je prijs per kWh in om direct de kosten per dag, week, maand en jaar te berekenen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(tariffSummaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tariffRow(
        label: String,
        placeholder: String,
        text: Binding<String>,
        field: PriceField,
        allowNegative: Bool = false,
        onChange: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            TextField(placeholder, text: text)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .focused($focusedField, equals: field)
                #if os(iOS)
                .keyboardType(allowNegative ? .numbersAndPunctuation : .decimalPad)
                #endif
                .frame(maxWidth: 120)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: text.wrappedValue) { onChange() }
        }
    }

    private var tariffSummaryLine: String {
        var parts = ["€ \(Format.number(priceImport, decimals: 4))/kWh\(hasOffpeak ? " piek" : "")"]
        if hasOffpeak {
            parts.append("€ \(Format.number(priceImportOffpeak, decimals: 4))/kWh dal")
        }
        if priceExport > 0 {
            parts.append("€ \(Format.number(priceExport, decimals: 4))/kWh terug")
        }
        if fixedDailyCost != 0 {
            parts.append("\(Format.euro(fixedDailyCost))/dag vast")
        }
        return "Gerekend met " + parts.joined(separator: " · ") + "."
    }

    // MARK: Samenvatting (Dag / Week / Maand / Jaar)

    private func summaryGrid(_ summary: CostSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            summaryTile(title: "Vandaag", target: .day, data: summary.day)
            summaryTile(title: "Deze week", target: .week, data: summary.week)
            summaryTile(title: "Deze maand", target: .month, data: summary.month)
            summaryTile(title: "Dit jaar", target: .year, data: summary.year)
        }
    }

    private func summaryTile(title: String, target: CostPeriod, data: CostPeriodSummary) -> some View {
        let calculated = costFor(summary: data)
        let isSelected = period == target
        return Button {
            period = target
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if isSelected {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                    }
                }
                if let calculated {
                    Text(Format.euro(calculated))
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(calculated < 0 ? Color.l3 : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("\(Format.number(data.kwhImport, decimals: target == .year ? 0 : 1)) kWh")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(Format.number(data.kwhImport, decimals: target == .year ? 0 : 1)) kWh")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text("Vul tarief in")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if data.kwhExport > 0 {
                    Text("↓ \(Format.number(data.kwhExport, decimals: target == .year ? 0 : 1)) kWh terug")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.l3)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    // MARK: Grafiek

    private var periodChart: some View {
        let values = entries.map { chartValue(for: $0) }
        let average = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)

        return VStack(alignment: .leading, spacing: 10) {
            if let entry = selectedEntry {
                HStack {
                    Text(Self.formatPeriodTitle(entry.localDate, period: period))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    if let cost = costFor(entry: entry) {
                        Text("\(Format.euro(cost)) · \(Format.number(entry.kwhImport, decimals: 1)) kWh")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(Format.number(entry.kwhImport, decimals: 1)) kWh")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Chart {
                ForEach(entries) { entry in
                    let val = chartValue(for: entry)
                    let isHighlighted = selectedEntry == nil || selectedEntry?.id == entry.id
                    BarMark(
                        x: .value("Periode", entry.start, unit: calendarUnit),
                        y: .value(hasPrice ? "Kosten" : "kWh", val)
                    )
                    .foregroundStyle((val < 0 ? Color.l3 : Color.accentColor).opacity(isHighlighted ? 1 : 0.35))
                    .cornerRadius(4)
                }
                if entries.count > 1 {
                    RuleMark(y: .value("Gemiddelde", average))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("Gem. \(hasPrice ? Format.euro(average) : "\(Format.number(average, decimals: 1)) kWh")")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .chartYAxisLabel(hasPrice ? "€" : "kWh")
            .chartXSelection(value: $selectedDate)
            .frame(height: 220)
            .accessibilityLabel("\(hasPrice ? "Kosten" : "Verbruik") \(period.perLabel)")
        }
    }

    // MARK: Overzichtstabel

    private var periodList: some View {
        let totalImport = entries.reduce(0) { $0 + $1.kwhImport }
        let totalPeak = entries.reduce(0) { $0 + ($1.kwhImportPeak ?? 0) }
        let totalOffpeak = entries.reduce(0) { $0 + ($1.kwhImportOffpeak ?? 0) }
        let totalExport = entries.reduce(0) { $0 + $1.kwhExport }
        let totalDays = entries.reduce(0) { $0 + ($1.daysCount ?? 0) }
        let hasPeakSplit = entries.allSatisfy { $0.kwhImportPeak != nil && $0.kwhImportOffpeak != nil }
        let totalCost = Format.cost(
            importKwh: totalImport,
            exportKwh: totalExport,
            priceImport: priceImport,
            priceExport: priceExport,
            peakKwh: hasPeakSplit ? totalPeak : nil,
            offpeakKwh: hasPeakSplit ? totalOffpeak : nil,
            priceOffpeak: priceImportOffpeak,
            daysCount: totalDays,
            fixedDailyCost: fixedDailyCost
        )
        let averageImport = entries.isEmpty ? 0 : totalImport / Double(entries.count)
        let averageCost = totalCost.map { entries.isEmpty ? 0 : $0 / Double(entries.count) }
        let reversed = Array(entries.reversed())

        return VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Totaal (\(entries.count) \(periodPlural(entries.count)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Format.number(totalImport, decimals: 1)) kWh")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                Spacer()
                if let totalCost, let averageCost {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Format.euro(totalCost))
                            .font(.headline.monospacedDigit())
                        Text("Gem. \(Format.euro(averageCost)) \(period.perLabel)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Gem. \(Format.number(averageImport, decimals: 1)) kWh")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            Divider()

            ForEach(reversed) { entry in
                let cost = costFor(entry: entry)
                let decimals = period == .year ? 0 : 1
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.formatPeriodTitle(entry.localDate, period: period))
                        HStack(spacing: 8) {
                            Text("\(Format.number(entry.kwhImport, decimals: decimals)) kWh")
                            if hasOffpeak, let peak = entry.kwhImportPeak, let offpeak = entry.kwhImportOffpeak {
                                Text("(\(Format.number(peak, decimals: decimals)) piek / \(Format.number(offpeak, decimals: decimals)) dal)")
                            }
                            if entry.kwhExport > 0 {
                                Text("↓ \(Format.number(entry.kwhExport, decimals: decimals)) kWh")
                                    .foregroundStyle(Color.l3)
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let cost {
                        Text(Format.euro(cost))
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(cost < 0 ? Color.l3 : .primary)
                    } else {
                        Text("\(Format.number(entry.kwhImport, decimals: 1)) kWh")
                            .font(.headline.monospacedDigit())
                    }
                }
                .accessibilityElement(children: .combine)
                if entry.id != reversed.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: CSV-export

    private var csvExport: CostCSVExport {
        var lines = [
            "Periode;Datum;Afname (kWh);Piek (kWh);Dal (kWh);Teruglevering (kWh);Dagen;Tarief afname (€/kWh);Tarief dal (€/kWh);Tarief teruglevering (€/kWh);Vaste kosten (€/dag);Kosten (€)"
        ]
        var totalImport = 0.0
        var totalPeak = 0.0
        var totalOffpeak = 0.0
        var totalExport = 0.0
        var totalDays = 0
        var totalCost = 0.0
        var hasCostValues = false

        for entry in entries {
            let cost = costFor(entry: entry)
            totalImport += entry.kwhImport
            totalPeak += entry.kwhImportPeak ?? 0
            totalOffpeak += entry.kwhImportOffpeak ?? 0
            totalExport += entry.kwhExport
            totalDays += entry.daysCount ?? 0
            if let cost {
                totalCost += cost
                hasCostValues = true
            }
            let row = [
                Self.csvCell(Self.formatPeriodTitle(entry.localDate, period: period)),
                entry.localDate,
                Self.csvNumber(entry.kwhImport, decimals: 3),
                entry.kwhImportPeak.map { Self.csvNumber($0, decimals: 3) } ?? "",
                entry.kwhImportOffpeak.map { Self.csvNumber($0, decimals: 3) } ?? "",
                Self.csvNumber(entry.kwhExport, decimals: 3),
                entry.daysCount.map(String.init) ?? "",
                priceImport > 0 ? Self.csvNumber(priceImport, decimals: 4) : "",
                priceImportOffpeak > 0 ? Self.csvNumber(priceImportOffpeak, decimals: 4) : "",
                priceExport > 0 ? Self.csvNumber(priceExport, decimals: 4) : "",
                fixedDailyCost != 0 ? Self.csvNumber(fixedDailyCost, decimals: 4) : "",
                cost.map { Self.csvNumber($0, decimals: 2) } ?? "",
            ]
            lines.append(row.joined(separator: ";"))
        }

        let summaryRow = [
            "Totaal",
            "",
            Self.csvNumber(totalImport, decimals: 3),
            Self.csvNumber(totalPeak, decimals: 3),
            Self.csvNumber(totalOffpeak, decimals: 3),
            Self.csvNumber(totalExport, decimals: 3),
            String(totalDays),
            "", "", "", "",
            hasCostValues ? Self.csvNumber(totalCost, decimals: 2) : "",
        ]
        lines.append(summaryRow.joined(separator: ";"))

        return CostCSVExport(
            filename: "wattnu-kosten-\(period.label.lowercased()).csv",
            content: lines.joined(separator: "\r\n")
        )
    }

    private static func csvNumber(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value).replacingOccurrences(of: ".", with: ",")
    }

    private static func csvCell(_ value: String) -> String {
        if value.contains(";") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }

    // MARK: Berekeningen & opslag

    private var calendarUnit: Calendar.Component {
        switch period {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        case .year: return .year
        }
    }

    private func chartValue(for entry: CostEntry) -> Double {
        costFor(entry: entry) ?? entry.kwhImport
    }

    private func costFor(summary: CostPeriodSummary) -> Double? {
        Format.cost(
            importKwh: summary.kwhImport,
            exportKwh: summary.kwhExport,
            priceImport: priceImport,
            priceExport: priceExport,
            peakKwh: summary.kwhImportPeak,
            offpeakKwh: summary.kwhImportOffpeak,
            priceOffpeak: priceImportOffpeak,
            daysCount: summary.daysCount ?? 0,
            fixedDailyCost: fixedDailyCost
        )
    }

    private func costFor(entry: CostEntry) -> Double? {
        Format.cost(
            importKwh: entry.kwhImport,
            exportKwh: entry.kwhExport,
            priceImport: priceImport,
            priceExport: priceExport,
            peakKwh: entry.kwhImportPeak,
            offpeakKwh: entry.kwhImportOffpeak,
            priceOffpeak: priceImportOffpeak,
            daysCount: entry.daysCount ?? 0,
            fixedDailyCost: fixedDailyCost
        )
    }

    private func periodPlural(_ count: Int) -> String {
        switch period {
        case .day: return count == 1 ? "dag" : "dagen"
        case .week: return count == 1 ? "week" : "weken"
        case .month: return count == 1 ? "maand" : "maanden"
        case .year: return count == 1 ? "jaar" : "jaren"
        }
    }

    private func syncTextFromStorage() {
        isSyncingText = true
        importText = priceImport > 0 ? Self.formatEditableNumber(priceImport) : ""
        offpeakText = priceImportOffpeak > 0 ? Self.formatEditableNumber(priceImportOffpeak) : ""
        exportText = priceExport > 0 ? Self.formatEditableNumber(priceExport) : ""
        fixedText = fixedDailyCost != 0 ? Self.formatEditableNumber(fixedDailyCost) : ""
        isSyncingText = false
    }

    private func handleImportTextChange() {
        guard !isSyncingText else { return }
        let trimmed = importText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            priceImport = 0
            pendingSaveToken += 1
        } else if let value = Self.parseNumber(trimmed, range: 0...10) {
            priceImport = value
            pendingSaveToken += 1
        }
    }

    private func handleOffpeakTextChange() {
        guard !isSyncingText else { return }
        let trimmed = offpeakText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            priceImportOffpeak = 0
            pendingSaveToken += 1
        } else if let value = Self.parseNumber(trimmed, range: 0...10) {
            priceImportOffpeak = value
            pendingSaveToken += 1
        }
    }

    private func handleExportTextChange() {
        guard !isSyncingText else { return }
        let trimmed = exportText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            priceExport = 0
            pendingSaveToken += 1
        } else if let value = Self.parseNumber(trimmed, range: 0...10) {
            priceExport = value
            pendingSaveToken += 1
        }
    }

    private func handleFixedTextChange() {
        guard !isSyncingText else { return }
        let trimmed = fixedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            fixedDailyCost = 0
            pendingSaveToken += 1
        } else if let value = Self.parseNumber(trimmed, range: -20...100) {
            fixedDailyCost = value
            pendingSaveToken += 1
        }
    }

    private func load() async {
        guard !isPreview, let client = APIClient.current else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await client.costs(period: period, count: period.defaultCount)
            response = loaded
            errorText = nil
            if focusedField == nil {
                if let serverImport = loaded.priceImport, serverImport > 0 { priceImport = serverImport }
                if let serverOffpeak = loaded.priceImportOffpeak, serverOffpeak > 0 { priceImportOffpeak = serverOffpeak }
                if let serverExport = loaded.priceExport, serverExport > 0 { priceExport = serverExport }
                if let serverFixed = loaded.fixedDailyCost, serverFixed != 0 { fixedDailyCost = serverFixed }
                if hasAdvancedValues { showAdvancedTariffs = true }
                syncTextFromStorage()
            }
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch APIError.server(404, _) {
            errorText = "Je WattServer is nog een oudere versie zonder /api/costs. Werk de Pi bij met docker compose up -d --build api."
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveTariffsToServer() async {
        guard !isPreview, let client = APIClient.current else { return }
        do {
            var current = try await client.settings().settings
            current.priceImport = priceImport > 0 ? priceImport : nil
            current.priceImportOffpeak = priceImportOffpeak > 0 ? priceImportOffpeak : nil
            current.priceExport = priceExport > 0 ? priceExport : nil
            current.fixedDailyCost = fixedDailyCost != 0 ? fixedDailyCost : nil
            let updated = try await client.updateSettings(current)
            AppSettings.cachePrices(from: updated.settings)
            saveStatus = "Tarieven opgeslagen op de Pi."
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            saveStatus = "Lokaal toegepast, maar opslaan op de Pi mislukte: \(error.localizedDescription)"
        }
    }

    // MARK: Datum- en getalopmaak

    private static let dutchLocale = Locale(identifier: "nl_NL")
    private static let amsterdamTimeZone = TimeZone(identifier: "Europe/Amsterdam") ?? .current

    private static let isoDateParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = amsterdamTimeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static var amsterdamCalendar: Calendar {
        var cal = Calendar(identifier: .iso8601)
        cal.timeZone = amsterdamTimeZone
        cal.locale = dutchLocale
        return cal
    }

    private static func formatEditableNumber(_ value: Double) -> String {
        value.formatted(.number.locale(dutchLocale).precision(.fractionLength(0...4)).grouping(.never))
    }

    private static func parseNumber(_ text: String, range: ClosedRange<Double>) -> Double? {
        let normalized = text
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "−", with: "-")
        guard let value = Double(normalized), range.contains(value) else { return nil }
        return value
    }

    private static func formatPeriodTitle(_ localDate: String, period: CostPeriod) -> String {
        guard let date = isoDateParser.date(from: localDate) else { return localDate }
        let cal = amsterdamCalendar
        let now = Date()

        switch period {
        case .day:
            if cal.isDate(date, inSameDayAs: now) { return "Vandaag" }
            if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
               cal.isDate(date, inSameDayAs: yesterday) {
                return "Gisteren"
            }
            let formatter = DateFormatter()
            formatter.locale = dutchLocale
            formatter.timeZone = amsterdamTimeZone
            formatter.dateFormat = "EEE d MMM"
            return formatter.string(from: date)

        case .week:
            let weekNumber = cal.component(.weekOfYear, from: date)
            let isCurrentWeek = cal.component(.weekOfYear, from: now) == weekNumber
                && cal.component(.yearForWeekOfYear, from: now) == cal.component(.yearForWeekOfYear, from: date)
            let formatter = DateFormatter()
            formatter.locale = dutchLocale
            formatter.timeZone = amsterdamTimeZone
            formatter.dateFormat = "d MMM"
            let startText = formatter.string(from: date)
            let endText = cal.date(byAdding: .day, value: 6, to: date).map(formatter.string(from:)) ?? ""
            let prefix = isCurrentWeek ? "Deze week (wk \(weekNumber))" : "Week \(weekNumber)"
            return endText.isEmpty ? prefix : "\(prefix) · \(startText)–\(endText)"

        case .month:
            let formatter = DateFormatter()
            formatter.locale = dutchLocale
            formatter.timeZone = amsterdamTimeZone
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: date).capitalized

        case .year:
            return String(localDate.prefix(4))
        }
    }
}

struct CostCSVExport: Transferable {
    let filename: String
    let content: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .commaSeparatedText) { export in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(export.filename)
            let bom = Data([0xEF, 0xBB, 0xBF])
            let body = Data(export.content.utf8)
            try (bom + body).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

#Preview("Kosten — Dag") {
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd"
    let entries = (0..<14).map { offset -> CostEntry in
        let date = cal.date(byAdding: .day, value: offset - 13, to: today)!
        let peak = 5.5 + Double(offset % 4) * 1.6
        let offpeak = 4.2 + Double((offset + 1) % 3) * 1.1
        return CostEntry(
            start: date,
            localDate: fmt.string(from: date),
            kwhImport: peak + offpeak,
            kwhImportPeak: peak,
            kwhImportOffpeak: offpeak,
            kwhExport: Double(offset % 3) * 1.8,
            daysCount: 1,
            cost: nil
        )
    }
    let summary = CostSummary(
        day: CostPeriodSummary(kwhImport: 11.4, kwhImportPeak: 6.8, kwhImportOffpeak: 4.6, kwhExport: 2.1, daysCount: 1, cost: nil),
        week: CostPeriodSummary(kwhImport: 74.2, kwhImportPeak: 42.0, kwhImportOffpeak: 32.2, kwhExport: 12.5, daysCount: 7, cost: nil),
        month: CostPeriodSummary(kwhImport: 284.0, kwhImportPeak: 158.0, kwhImportOffpeak: 126.0, kwhExport: 42.0, daysCount: 23, cost: nil),
        year: CostPeriodSummary(kwhImport: 3120.0, kwhImportPeak: 1710.0, kwhImportOffpeak: 1410.0, kwhExport: 980.0, daysCount: 327, cost: nil)
    )
    return CostsView(previewResponse: CostsResponse(
        period: .day,
        priceImport: 0.30,
        priceImportOffpeak: 0.24,
        priceExport: 0.07,
        fixedDailyCost: 0.85,
        summary: summary,
        entries: entries
    ))
}
