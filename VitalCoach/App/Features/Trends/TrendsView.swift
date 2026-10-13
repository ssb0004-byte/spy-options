import Charts
import SwiftUI
import VitalCore

enum TrendRange: String, CaseIterable, Identifiable {
    case month = "30D", quarter = "90D", year = "1Y", all = "All"
    var id: String { rawValue }
    func start(from end: Date) -> Date? {
        let cal = Calendar.current
        switch self {
        case .month: return cal.date(byAdding: .day, value: -29, to: end)
        case .quarter: return cal.date(byAdding: .day, value: -89, to: end)
        case .year: return cal.date(byAdding: .year, value: -1, to: end)
        case .all: return nil
        }
    }
}

/// A self-reported series from check-ins.
enum CheckInSeries: String, CaseIterable, Identifiable {
    case wellbeing = "Wellbeing", energy = "Energy", clarity = "Mental clarity", stiffness = "Stiffness", pain = "Worst pain"
    var id: String { rawValue }
    var scale: ClosedRange<Double> { self == .stiffness || self == .pain ? 0...10 : 1...5 }
}

struct TrendsView: View {
    @Environment(AppModel.self) var model
    @State var range: TrendRange = .quarter
    @State var metric: MetricKind = .bodyMass
    @State var showingAdd = false

    private var metricsWithData: [MetricKind] {
        MetricKind.allCases.filter { k in model.data.measurements.contains { $0.kind == k } }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    Picker("Range", selection: $range) {
                        ForEach(TrendRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    if metricsWithData.isEmpty {
                        EmptyStateView(title: "No measurements yet",
                                       message: "Connect Apple Health in Profile or add a measurement manually. Charts only show real data you've recorded.",
                                       systemImage: "chart.xyaxis.line", actionTitle: "Add measurement") { showingAdd = true }
                    } else {
                        Picker("Metric", selection: $metric) {
                            ForEach(metricsWithData) { Text($0.displayName).tag($0) }
                        }
                        .pickerStyle(.menu)
                        MetricTrendCard(kind: metric, range: range)
                    }
                    CheckInTrendsCard(range: range)
                    GoalIndicatorsCard()
                }
                .padding(Theme.Spacing.l)
            }
            .background(Theme.pageBackground)
            .navigationTitle("Trends")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Label("Add measurement", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddMeasurementView(initialKind: metric) }
            .onAppear {
                if !metricsWithData.contains(metric), let first = metricsWithData.first { metric = first }
            }
        }
    }
}

struct MetricTrendCard: View {
    @Environment(AppModel.self) var model
    var kind: MetricKind
    var range: TrendRange

    var body: some View {
        let cal = Calendar.current
        let units = model.data.units
        let samples = model.data.measurements(kind)
        let end = Date()
        let start = range.start(from: end) ?? samples.map(\.startAt).min() ?? end
        let daily = TrendCalculator.daily(samples.filter { $0.startAt >= cal.startOfDay(for: start) }, calendar: cal)
        let summary = TrendCalculator.summarize(daily, from: start, to: end, calendar: cal)
        let gaps = TrendCalculator.gaps(daily, from: start, to: end, minimumGapDays: 7, calendar: cal)
        let sources = Set(samples.compactMap(\.sourceName)).sorted()

        Card(title: kind.displayName, systemImage: "chart.xyaxis.line") {
            if daily.isEmpty {
                Text("No \(kind.displayName.lowercased()) data in this range.").font(.callout).foregroundStyle(VitalColors.textSecondary)
            } else {
                Chart(daily) { p in
                    LineMark(x: .value("Date", p.day, unit: .day),
                             y: .value(kind.displayName, MetricDisplay.fromCanonical(p.value, kind: kind, units: units)))
                        .interpolationMethod(.linear)
                        .foregroundStyle(Theme.accent.opacity(0.5))
                    PointMark(x: .value("Date", p.day, unit: .day),
                              y: .value(kind.displayName, MetricDisplay.fromCanonical(p.value, kind: kind, units: units)))
                        .foregroundStyle(by: .value("Quality", QualityBadge(quality: p.quality).label))
                        .symbolSize(daily.count > 60 ? 12 : 30)
                }
                .chartForegroundStyleScale(["Measured": VitalColors.chart[0], "Estimate": VitalColors.chart[2], "Self-reported": VitalColors.chart[1], "Calculated": VitalColors.chart[5]])
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxisLabel(MetricDisplay.unitLabel(kind, units: units))
                .frame(height: 220)
                .accessibilityLabel("\(kind.displayName) chart with \(daily.count) days of data")

                summaryView(summary, units: units)
            }
            if !gaps.isEmpty {
                Text("\(gaps.count) gap\(gaps.count == 1 ? "" : "s") of a week or more with no data. Gaps are shown as missing, not estimated.")
                    .font(.caption).foregroundStyle(VitalColors.textSecondary)
            }
            if let explanation = kind.explanation {
                Text(explanation).font(.caption).foregroundStyle(VitalColors.textSecondary)
            }
            if !sources.isEmpty {
                Text("Sources: \(sources.joined(separator: ", "))").font(.caption2).foregroundStyle(VitalColors.textSecondary)
            }
            NavigationLink("All entries") { MeasurementListView(kind: kind) }.font(.callout)
        }
    }

    @ViewBuilder
    private func summaryView(_ s: TrendSummary, units: UnitSystem) -> some View {
        HStack(alignment: .top) {
            if let latest = s.latest {
                MetricTile(title: "Latest daily value", value: MetricDisplay.format(latest, kind: kind, units: units))
            }
            if s.isSufficient, let slope = s.slopePerWeek {
                let display = MetricDisplay.fromCanonical(slope, kind: kind, units: units) - MetricDisplay.fromCanonical(0, kind: kind, units: units)
                MetricTile(title: "Trend per week",
                           value: "\(display >= 0 ? "+" : "")\(display.formatted(.number.precision(.fractionLength(kind.isCumulative ? 0 : 2)))) \(MetricDisplay.unitLabel(kind, units: units))")
            } else {
                MetricTile(title: "Trend per week", value: "—", detail: "Needs \(TrendCalculator.minimumPoints)+ days")
            }
        }
        Text("Data on \(s.daysWithData) of \(s.dayCount) days. Trends describe change over time; they don't show what caused it.")
            .font(.caption2).foregroundStyle(VitalColors.textSecondary)
    }
}

struct CheckInTrendsCard: View {
    @Environment(AppModel.self) var model
    var range: TrendRange
    @State var series: CheckInSeries = .wellbeing

    private func points(start: Date) -> [DailyPoint] {
        let cal = Calendar.current
        let entries = model.data.symptomEntries.filter { $0.recordedAt >= start }
        var byDay: [Date: [Double]] = [:]
        switch series {
        case .pain:
            for p in model.data.painEntries where p.recordedAt >= start {
                byDay[cal.startOfDay(for: p.recordedAt), default: []].append(Double(p.severity))
            }
            return byDay.map { DailyPoint(day: $0.key, value: $0.value.max() ?? 0, sampleCount: $0.value.count, quality: .selfReported) }
                .sorted { $0.day < $1.day }
        default:
            for e in entries {
                let v: Int? = switch series {
                case .wellbeing: e.wellbeing
                case .energy: e.energy
                case .clarity: e.cognitiveClarity
                case .stiffness: e.stiffness
                case .pain: nil
                }
                if let v { byDay[cal.startOfDay(for: e.recordedAt), default: []].append(Double(v)) }
            }
            return byDay.map { DailyPoint(day: $0.key, value: $0.value.reduce(0, +) / Double($0.value.count), sampleCount: $0.value.count, quality: .selfReported) }
                .sorted { $0.day < $1.day }
        }
    }

    var body: some View {
        let start = range.start(from: Date()) ?? .distantPast
        let pts = points(start: start)
        Card(title: "How you've felt", systemImage: "face.smiling") {
            Picker("Series", selection: $series) {
                ForEach(CheckInSeries.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)
            if pts.isEmpty {
                Text("No check-in answers for this in the selected range.").font(.callout).foregroundStyle(VitalColors.textSecondary)
            } else {
                Chart(pts) { p in
                    PointMark(x: .value("Date", p.day, unit: .day), y: .value(series.rawValue, p.value))
                        .foregroundStyle(VitalColors.chart[1])
                    LineMark(x: .value("Date", p.day, unit: .day), y: .value(series.rawValue, p.value))
                        .foregroundStyle(VitalColors.chart[1].opacity(0.4))
                }
                .chartYScale(domain: series.scale)
                .frame(height: 180)
                .accessibilityLabel("\(series.rawValue) self-reported, \(pts.count) days")
                Text("Self-reported. Only days you answered are shown.").font(.caption2).foregroundStyle(VitalColors.textSecondary)
            }
        }
    }
}

struct GoalIndicatorsCard: View {
    @Environment(AppModel.self) var model

    var body: some View {
        let goals = model.data.activeGoals
        if !goals.isEmpty {
            Card(title: "What to watch for your goals", systemImage: "target") {
                ForEach(goals) { g in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.displayName).font(.subheadline.weight(.medium))
                        Text(g.suggestedIndicators.joined(separator: " · ")).font(.caption).foregroundStyle(VitalColors.textSecondary)
                    }
                }
            }
        }
    }
}

struct MeasurementListView: View {
    @Environment(AppModel.self) var model
    var kind: MetricKind

    var body: some View {
        let items = model.data.measurements(kind).sorted { $0.startAt > $1.startAt }
        List {
            ForEach(items) { m in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(MetricDisplay.format(m.value, kind: kind, units: model.data.units)).font(.body.monospacedDigit())
                        Spacer()
                        QualityBadge(quality: m.quality)
                    }
                    Text("\(m.startAt.formatted(date: .abbreviated, time: .shortened)) · \(m.sourceName ?? m.sourceKind.rawValue)")
                        .font(.caption).foregroundStyle(VitalColors.textSecondary)
                    if let note = m.note { Text(note).font(.caption) }
                }
                .swipeActions {
                    if m.sourceKind == .manual {
                        Button("Delete", role: .destructive) { Task { await model.deleteMeasurement(m) } }
                    }
                }
            }
        }
        .vitalListBackground()
        .overlay {
            if items.isEmpty { EmptyStateView(title: "No entries", message: "Nothing recorded yet.", systemImage: "list.bullet") }
        }
        .navigationTitle(kind.displayName)
        .safeAreaInset(edge: .bottom) {
            Text("Apple Health entries are edited in the Health app; changes sync here automatically.")
                .font(.caption2).foregroundStyle(VitalColors.textSecondary).padding()
        }
    }
}

struct AddMeasurementView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var initialKind: MetricKind = .bodyMass

    @State var kind: MetricKind = .bodyMass
    @State var valueText = ""
    @State var date = Date()
    @State var note = ""
    @State var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Picker("Measurement", selection: $kind) {
                    ForEach(MetricKind.manualEntryKinds) { Text($0.displayName).tag($0) }
                }
                HStack {
                    TextField("Value", text: $valueText).keyboardType(.decimalPad)
                    Text(MetricDisplay.unitLabel(kind, units: model.data.units)).foregroundStyle(VitalColors.textSecondary)
                }
                DatePicker("When", selection: $date, in: ...Date())
                TextField("Note (optional)", text: $note)
                if let explanation = kind.explanation {
                    Section { Text(explanation).font(.footnote).foregroundStyle(VitalColors.textSecondary) }
                    .vitalRow()
                }
                if let error { Section { Text(error).foregroundStyle(VitalColors.critical) } }
            }
            .vitalListBackground()
            .navigationTitle("Add measurement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let v = Double(valueText.replacingOccurrences(of: ",", with: ".")) else {
                            error = "Please enter a number."; return
                        }
                        Task {
                            error = await model.addMeasurement(kind: kind, displayValue: v, at: date, note: note.nilIfBlank)
                            if error == nil { dismiss() }
                        }
                    }
                    .disabled(valueText.isEmpty)
                }
            }
            .onAppear { if MetricKind.manualEntryKinds.contains(initialKind) { kind = initialKind } }
        }
    }
}
