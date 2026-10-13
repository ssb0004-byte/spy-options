import SwiftUI
import VitalCore

struct HomeView: View {
    @Environment(AppModel.self) var model
    @State var showingCheckIn = false
    @State var showingAddMeasurement = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VitalSpacing.l) {
                    greeting
                    alerts
                    BriefingCard()
                    BiometricsCard(showingAddMeasurement: $showingAddMeasurement)
                    TodayScheduleCard()
                    checkInCard
                }
                .padding(.horizontal, VitalSpacing.page)
                .padding(.bottom, VitalSpacing.xl)
            }
            .vitalScreenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .refreshable {
                await model.importHealthData()
                await model.syncNow()
            }
            .sheet(isPresented: $showingCheckIn) { CheckInView() }
            .sheet(isPresented: $showingAddMeasurement) { AddMeasurementView() }
            .task { await model.loadBriefing() }
        }
    }

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = model.data.profile?.displayName.map { ", \($0)" } ?? ""
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                    .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                Text("\(part)\(name)").vitalFont(.title).foregroundStyle(VitalColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: VitalSpacing.xs)
            VitalLogoMark(size: 36)
        }
        .padding(.top, VitalSpacing.m)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var alerts: some View {
        if model.isLocalOnly {
            NoticeBanner(style: .info, text: "Device-only mode: your data is stored on this iPhone and isn't backed up.")
        } else if !model.data.consents.isGranted(.cloudSync) {
            NoticeBanner(style: .info, text: "Cloud backup is off. Turn it on in Profile → Privacy to keep your records safe if you lose this iPhone.")
        }
        if let msg = model.syncStatus.message { NoticeBanner(style: .warning, text: msg) }
        if let last = model.data.symptomEntries.last, Calendar.current.isDateInToday(last.recordedAt) {
            let pain = model.data.painEntries.filter { $0.symptomEntryId == last.id }
            if UrgentSymptomScreen.screen(text: [last.note, last.sideEffectsNote].compactMap { $0 }.joined(separator: " "), pain: pain).isUrgent {
                NoticeBanner(style: .critical, text: UrgentSymptomScreen.message)
            }
        }
    }

    private var checkInCard: some View {
        let cal = Calendar.current
        let doneToday = model.data.symptomEntries.contains { cal.isDateInToday($0.recordedAt) }
        let lastWeek = (0..<7).filter { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { return false }
            return model.data.symptomEntries.contains { cal.isDate($0.recordedAt, inSameDayAs: day) }
        }.count
        return VitalCard {
            HStack(spacing: VitalSpacing.m) {
                VitalProgressIndicator(value: Double(lastWeek) / 7, label: "Last 7 days", style: .ring)
                    .frame(width: 84, height: 84)
                VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                    Text("Daily check-in").vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text(doneToday ? "Done for today. Thanks — consistency makes trends meaningful."
                                   : "Under a minute. Questions adapt to your goals.")
                        .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                    VitalButton(title: doneToday ? "Add another" : "Start check-in", kind: doneToday ? .secondary : .primary) {
                        showingCheckIn = true
                    }
                    .padding(.top, VitalSpacing.xxs)
                    .accessibilityIdentifier("home.checkIn")
                }
            }
        }
    }
}

/// Today's AI briefing (generated once per day on the server), or what's needed to enable it.
struct BriefingCard: View {
    @Environment(AppModel.self) var model

    var body: some View {
        switch model.coachAvailability {
        case .ready:
            if let b = model.briefing {
                VitalInsightCard(title: b.title, message: b.body, basis: basisText(b)) {
                    refreshButton
                }
                .textSelection(.enabled)
            } else if model.isLoadingBriefing {
                VitalInsightCard(title: "Preparing your briefing", message: "Looking at your latest data…") {
                    VitalLoadingState(text: "This takes a few seconds.")
                }
            } else if let msg = model.briefingMessage {
                VitalInsightCard(title: "Morning briefing", message: msg) { refreshButton }
            } else {
                VitalInsightCard(title: "Morning briefing", message: "A short summary of what changed in your data, generated once a day.") {
                    VitalButton(title: "Get today's briefing", systemImage: "sparkles") { Task { await model.loadBriefing() } }
                }
            }
        case .deviceOnly:
            VitalInsightCard(title: "Morning briefing", message: "Sign in with Apple to get a daily AI briefing based on your data.")
        case .needsCloudBackup, .needsAIConsent:
            VitalInsightCard(title: "Morning briefing", message: "Turn on AI coaching in the Coach tab to get a short daily briefing based on your data.")
        }
    }

    private var refreshButton: some View {
        Button { Task { await model.loadBriefing(force: true) } } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(VitalButtonStyle(kind: .tertiary, fullWidth: false))
        .disabled(model.isLoadingBriefing)
    }

    /// "Based on your data · Used: weight, check-ins" — what the briefing drew on.
    private func basisText(_ b: CoachInsight) -> String? {
        var meta = CoachMetadata()
        meta.basis = b.payload?.basis
        let points = (b.payload?.dataPointsUsed ?? []).filter { !$0.isEmpty }
        let parts = [meta.basisLabel, points.isEmpty ? nil : "Used: " + points.joined(separator: " · ")].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

struct BiometricsCard: View {
    @Environment(AppModel.self) var model
    @Binding var showingAddMeasurement: Bool

    private let kinds: [MetricKind] = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex, .restingHeartRate, .heartRateVariabilitySDNN, .stepCount, .waistCircumference]

    var body: some View {
        let available = kinds.filter { model.data.latest($0) != nil }
        VStack(alignment: .leading, spacing: VitalSpacing.s) {
            VitalSectionHeader(title: "Your metrics", actionTitle: "Add") { showingAddMeasurement = true }
            if available.isEmpty {
                VitalCard {
                    VitalEmptyState(title: "No measurements yet",
                                    message: "Connect Apple Health in Profile, or add one manually.",
                                    systemImage: "waveform.path.ecg", actionTitle: "Add measurement") { showingAddMeasurement = true }
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: VitalSpacing.s), GridItem(.flexible())], spacing: VitalSpacing.s) {
                    ForEach(available) { kind in metricCard(kind) }
                }
            }
        }
    }

    private func metricCard(_ kind: MetricKind) -> some View {
        let m = model.data.latest(kind)!
        let units = model.data.units
        let cal = Calendar.current
        let since = cal.date(byAdding: .day, value: -13, to: cal.startOfDay(for: Date())) ?? Date()
        let daily = TrendCalculator.daily(model.data.measurements(kind).filter { $0.startAt >= since }, calendar: cal)
        let values = daily.map { MetricDisplay.fromCanonical($0.value, kind: kind, units: units) }
        let caption = [m.sourceName, m.startAt.formatted(.relative(presentation: .named))].compactMap { $0 }.joined(separator: " · ")
        return VitalMetricCard(title: kind.displayName,
                               value: MetricDisplay.format(m.value, kind: kind, units: units),
                               systemImage: kind.symbolName,
                               trend: trend(values, kind: kind, units: units, days: daily.count),
                               caption: caption,
                               badge: m.quality == .measured ? nil : QualityBadge(quality: m.quality).label,
                               sparkline: values.count > 1 ? values : [])
    }

    /// Change across the points shown, stated neutrally: whether it's good depends on the goal.
    private func trend(_ values: [Double], kind: MetricKind, units: UnitSystem, days: Int) -> VitalTrend? {
        guard values.count >= 2, !kind.isCumulative, let first = values.first, let last = values.last else { return nil }
        let delta = last - first
        let precision = kind == .stepCount ? 0 : 1
        let text = "\(delta >= 0 ? "+" : "−")\(abs(delta).formatted(.number.precision(.fractionLength(precision)))) \(MetricDisplay.unitLabel(kind, units: units)) · \(days) d"
        let direction: VitalTrend.Direction = abs(delta) < 0.05 ? .flat : (delta > 0 ? .up : .down)
        return VitalTrend(direction: direction, text: direction == .flat ? "Stable · \(days) d" : text, isFavorable: nil)
    }
}

extension MetricKind {
    var symbolName: String {
        switch self {
        case .bodyMass: "scalemass"
        case .bodyFatPercentage: "percent"
        case .leanBodyMass, .fatFreeMass, .skeletalMuscleMass, .scaleMuscleMass: "figure.strengthtraining.traditional"
        case .bodyMassIndex: "figure"
        case .waistCircumference, .hipCircumference, .chestCircumference, .armCircumference, .thighCircumference: "ruler"
        case .heartRate, .restingHeartRate: "heart"
        case .heartRateVariabilitySDNN: "waveform.path.ecg"
        case .stepCount: "figure.walk"
        case .activeEnergy: "flame"
        case .height: "ruler"
        }
    }
}

/// Today's planned doses with one-tap confirmation. Nothing is marked taken automatically.
struct TodayScheduleCard: View {
    @Environment(AppModel.self) var model
    @State var correcting: PlannedDose?

    var body: some View {
        let planned = RoutinePlanner.planned(substances: model.data.substances, regimens: model.data.regimens,
                                             from: model.today, to: model.today, deviceTimeZone: .current)
        let logged = planned.filter {
            switch DoseLog.status(of: $0, records: model.data.administrations, now: Date()) {
            case .taken, .skipped: true
            default: false
            }
        }.count
        VStack(alignment: .leading, spacing: VitalSpacing.s) {
            VitalSectionHeader(title: "Today's routine", subtitle: planned.isEmpty ? nil : "\(logged) of \(planned.count) logged")
            VitalCard {
                if planned.isEmpty {
                    Text(model.data.substances.isEmpty ? "Add medications or supplements in the Routine tab." : "Nothing scheduled today.")
                        .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                } else {
                    VitalProgressIndicator(value: Double(logged) / Double(planned.count), label: "Doses logged today")
                    ForEach(planned) { p in
                        DoseRow(planned: p, onCorrect: { correcting = p })
                        if p.id != planned.last?.id { Divider().overlay(VitalColors.border) }
                    }
                }
            }
        }
        .sheet(item: $correcting) { p in DoseLogSheet(planned: p) }
    }
}

struct DoseRow: View {
    @Environment(AppModel.self) var model
    var planned: PlannedDose
    var onCorrect: () -> Void

    var body: some View {
        let status = DoseLog.status(of: planned, records: model.data.administrations, now: Date())
        let substance = model.data.substance(planned.userSubstanceId)
        let name = substance?.name ?? "Unknown"
        HStack(alignment: .center, spacing: VitalSpacing.s) {
            Image(systemName: (substance?.category ?? .other).symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(VitalColors.accent)
                .frame(width: 40, height: 40)
                .background(VitalColors.accentMuted, in: RoundedRectangle(cornerRadius: VitalRadii.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                Text("\(planned.dose.formatted) · \(planned.route.displayName) · \(planned.scheduledAt.formatted(date: .omitted, time: .shortened))")
                    .vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                if planned.wasShiftedByDST {
                    Label("Moved by daylight-saving change", systemImage: "clock.arrow.2.circlepath")
                        .vitalFont(.caption).foregroundStyle(VitalColors.caution)
                }
            }
            Spacer(minLength: 0)
            switch status {
            case .taken, .skipped, .missed:
                Button { onCorrect() } label: { StatusPill(status: status) }
                    .buttonStyle(.plain)
                    .frame(minHeight: VitalMetrics.minTouchTarget)
                    .accessibilityHint("Opens options to correct this entry")
            default:
                if status == .notLogged { StatusPill(status: status) }
                Button {
                    Task { await model.log(.taken, planned: planned) }
                } label: {
                    Image(systemName: "checkmark").font(.body.weight(.semibold))
                        .foregroundStyle(VitalColors.onAccent)
                        .frame(width: VitalMetrics.minTouchTarget, height: VitalMetrics.minTouchTarget)
                        .background(VitalColors.accentStrong, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark \(name) as taken")
                Menu {
                    Button("Taken at a different time…") { onCorrect() }
                    Button("Skipped") { Task { await model.log(.skipped, planned: planned) } }
                    Button("Missed") { Task { await model.log(.missed, planned: planned) } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                        .foregroundStyle(VitalColors.accentStrong)
                        .frame(width: VitalMetrics.minTouchTarget, height: VitalMetrics.minTouchTarget)
                }
                .accessibilityLabel("More options for \(name)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Dose status chip: icon + text so the state never depends on colour alone.
struct StatusPill: View {
    var status: DoseStatus

    var body: some View {
        VitalStatusIndicator(status: indicator, text: status.label, compact: true)
    }

    private var indicator: VitalStatusIndicator.Status {
        switch status {
        case .taken(let late): late ? .caution : .success
        case .skipped: .neutral
        case .missed: .critical
        case .notLogged: .caution
        case .due: .info
        case .upcoming: .neutral
        }
    }
}
