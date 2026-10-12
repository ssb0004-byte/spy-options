import SwiftUI
import VitalCore

struct HomeView: View {
    @Environment(AppModel.self) var model
    @State var showingCheckIn = false
    @State var showingAddMeasurement = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    greeting
                    alerts
                    BiometricsCard(showingAddMeasurement: $showingAddMeasurement)
                    TodayScheduleCard()
                    checkInCard
                    coachCard
                }
                .padding(Theme.Spacing.l)
            }
            .background(Theme.pageBackground)
            .navigationTitle("Today")
            .refreshable {
                await model.importHealthData()
                await model.syncNow()
            }
            .sheet(isPresented: $showingCheckIn) { CheckInView() }
            .sheet(isPresented: $showingAddMeasurement) { AddMeasurementView() }
        }
    }

    private var greeting: some View {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let name = model.data.profile?.displayName.map { ", \($0)" } ?? ""
        return Text("\(part)\(name)").font(.title2.weight(.semibold))
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
        let doneToday = model.data.symptomEntries.contains { Calendar.current.isDateInToday($0.recordedAt) }
        return Card(title: "Daily check-in", systemImage: "checkmark.circle") {
            if doneToday {
                Text("Done for today. Thanks — consistency makes trends meaningful.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Under a minute. Questions adapt to your goals.").font(.callout).foregroundStyle(.secondary)
            }
            Button(doneToday ? "Add another" : "Start check-in") { showingCheckIn = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var coachCard: some View {
        Card(title: "Coach", systemImage: "sparkles") {
            Text("Your AI coach arrives in the next update. Until then, Trends shows how your measurements are changing, calculated directly from your data.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct BiometricsCard: View {
    @Environment(AppModel.self) var model
    @Binding var showingAddMeasurement: Bool

    private let kinds: [MetricKind] = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex, .restingHeartRate, .heartRateVariabilitySDNN, .stepCount, .waistCircumference]

    var body: some View {
        Card(title: "Latest measurements", systemImage: "waveform.path.ecg") {
            let available = kinds.filter { model.data.latest($0) != nil }
            if available.isEmpty {
                Text("No measurements yet. Connect Apple Health in Profile, or add one manually.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: Theme.Spacing.m) {
                    ForEach(available) { kind in
                        let m = model.data.latest(kind)!
                        MetricTile(title: kind.displayName,
                                   value: MetricDisplay.format(m.value, kind: kind, units: model.data.units),
                                   detail: m.startAt.formatted(.relative(presentation: .named)),
                                   quality: m.quality)
                    }
                }
            }
            Button { showingAddMeasurement = true } label: { Label("Add measurement", systemImage: "plus") }
                .buttonStyle(.bordered)
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
        Card(title: "Today's routine", systemImage: "pills") {
            if planned.isEmpty {
                Text(model.data.substances.isEmpty ? "Add medications or supplements in the Routine tab." : "Nothing scheduled today.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(planned) { p in
                    DoseRow(planned: p, onCorrect: { correcting = p })
                    if p.id != planned.last?.id { Divider() }
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
        let name = model.data.substance(planned.userSubstanceId)?.name ?? "Unknown"
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.body.weight(.medium))
                Text("\(planned.dose.formatted) · \(planned.route.displayName) · \(planned.scheduledAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if planned.wasShiftedByDST {
                    Text("Moved by daylight-saving change").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            switch status {
            case .taken, .skipped, .missed:
                Button { onCorrect() } label: { StatusPill(status: status) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens options to correct this entry")
            default:
                if status == .notLogged { StatusPill(status: status) }
                Button {
                    Task { await model.log(.taken, planned: planned) }
                } label: {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).frame(width: 36, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .accessibilityLabel("Mark \(name) as taken")
                Menu {
                    Button("Taken at a different time…") { onCorrect() }
                    Button("Skipped") { Task { await model.log(.skipped, planned: planned) } }
                    Button("Missed") { Task { await model.log(.missed, planned: planned) } }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.title3)
                }
                .accessibilityLabel("More options for \(name)")
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct StatusPill: View {
    var status: DoseStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .taken(let late): late ? .orange : .green
        case .skipped: .gray
        case .missed: .red
        case .notLogged: .orange
        case .due: .teal
        case .upcoming: .secondary
        }
    }
}
