import SwiftUI
import VitalCore

struct RoutineView: View {
    @Environment(AppModel.self) var model
    @State var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(RoutineGroup.allCases) { group in
                    let items = model.data.substances.filter { group.statuses.contains($0.status) }.sorted { $0.name < $1.name }
                    if !items.isEmpty {
                        Section(group.rawValue) {
                            ForEach(items) { s in
                                NavigationLink { SubstanceDetailView(substanceId: s.id) } label: { SubstanceRow(substance: s) }
                            }
                        }
                        .vitalRow()
                    }
                }
            }
            .vitalListBackground()
            .overlay {
                if model.data.substances.isEmpty {
                    EmptyStateView(title: "Your routine is empty",
                                   message: "Add the medications, supplements or other substances you take so you can log doses and see them alongside your trends.",
                                   systemImage: "pills", actionTitle: "Add to routine") { showingAdd = true }
                }
            }
            .navigationTitle("My Routine")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Label("Add", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showingAdd) { AddSubstanceView() }
        }
    }
}

enum RoutineGroup: String, CaseIterable, Identifiable {
    case active = "Active", planned = "Planned", paused = "Paused", past = "Past"
    var id: String { rawValue }
    var statuses: [SubstanceStatus] {
        switch self {
        case .active: [.active]
        case .planned: [.planned]
        case .paused: [.paused]
        case .past: [.completed, .discontinued]
        }
    }
}

struct SubstanceRow: View {
    @Environment(AppModel.self) var model
    var substance: UserSubstance

    var body: some View {
        let regimen = RoutinePlanner.currentRegimen(for: substance.id, regimens: model.data.regimens, on: model.today)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(substance.name).font(.body.weight(.medium))
                if substance.isUserCreatedName {
                    Text("User-created").font(.caption2.weight(.medium)).foregroundStyle(VitalColors.caution)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(VitalColors.caution.opacity(0.12), in: Capsule())
                }
            }
            if let r = regimen {
                Text("\(r.dose.formatted) · \(r.route.displayName) · \(ScheduleText.describe(r.schedule))")
                    .font(.caption).foregroundStyle(VitalColors.textSecondary)
            } else {
                Text(substance.category.displayName).font(.caption).foregroundStyle(VitalColors.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum ScheduleText {
    static func describe(_ s: RegimenSchedule) -> String {
        let times = s.times.map(\.description).joined(separator: ", ")
        var base: String
        switch s.frequency {
        case .daily: base = "Daily at \(times)"
        case .everyNDays: base = "Every \(s.intervalDays ?? 1) days at \(times)"
        case .weekdays:
            let names = Calendar.current.shortWeekdaySymbols
            base = (s.weekdays ?? []).sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }.joined(separator: ", ") + " at \(times)"
        case .asNeeded: base = "As needed"
        }
        if let on = s.cycleOnDays, let off = s.cycleOffDays { base += " · \(on) on / \(off) off" }
        if let tz = s.timeZoneIdentifier { base += " (\(tz))" }
        return base
    }
}

/// Form state shared by "add" and "change dose/schedule".
struct RegimenDraft {
    var amountText = ""
    var unit: DoseUnit = .milligram
    var route: AdministrationRoute = .oral
    /// False until the user picks a route when the catalog has no single typical route
    /// (Smart Routine Entry never assumes injection, or any route, for them).
    var routeChosen = true
    var frequency: FrequencyType = .daily
    var intervalDays = 2
    var weekdays: Set<Int> = [2, 4, 6]
    var times: [Date] = [Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()]
    var useCycle = false
    var cycleOn = 5
    var cycleOff = 2
    var pinTimeZone = false
    var startDate = Date()
    var hasEndDate = false
    var endDate = Date()
    var reminders = true

    init() {}

    init(from r: SubstanceRegimen) {
        amountText = DoseQuantity.format(r.doseAmount); unit = r.doseUnit; route = r.route
        frequency = r.schedule.frequency; intervalDays = r.schedule.intervalDays ?? 2
        weekdays = Set(r.schedule.weekdays ?? [2, 4, 6])
        times = r.schedule.times.compactMap { Calendar.current.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: Date()) }
        useCycle = r.schedule.cycleOnDays != nil; cycleOn = r.schedule.cycleOnDays ?? 5; cycleOff = r.schedule.cycleOffDays ?? 2
        pinTimeZone = r.schedule.timeZoneIdentifier != nil; reminders = r.remindersEnabled
        startDate = Date()
    }

    var amount: Decimal? { DoseQuantity.parseAmount(amountText) }

    var schedule: RegimenSchedule {
        let cal = Calendar.current
        let localTimes = times.map { LocalTime(hour: cal.component(.hour, from: $0), minute: cal.component(.minute, from: $0)) }
        return RegimenSchedule(frequency: frequency,
                               intervalDays: frequency == .everyNDays ? intervalDays : nil,
                               weekdays: frequency == .weekdays ? weekdays.sorted() : nil,
                               times: frequency == .asNeeded ? [] : Array(Set(localTimes)),
                               cycleOnDays: useCycle ? cycleOn : nil, cycleOffDays: useCycle ? cycleOff : nil,
                               timeZoneIdentifier: pinTimeZone ? TimeZone.current.identifier : nil)
    }

    var validationMessage: String? {
        if amount == nil { return "Enter the dose exactly as prescribed or labelled (e.g. 0.25 or 1/2)." }
        if !routeChosen { return "Choose how you take it (route)." }
        do { try schedule.validate() } catch {
            switch error as? RegimenSchedule.ValidationError {
            case .noTimes: return "Add at least one time."
            case .noWeekdays: return "Choose at least one day."
            case .invalidInterval: return "Interval must be at least 1 day."
            default: return "Check the schedule settings."
            }
        }
        if hasEndDate && endDate < startDate { return "End date must be after the start date." }
        return nil
    }
}

struct RegimenFormSection: View {
    @Binding var draft: RegimenDraft
    /// Routes the catalog lists for this product; shown first. Empty → all routes in order.
    var typicalRoutes: [AdministrationRoute] = []

    private var routeOptions: [AdministrationRoute] {
        typicalRoutes + AdministrationRoute.allCases.filter { !typicalRoutes.contains($0) }
    }

    private var routeSelection: Binding<AdministrationRoute?> {
        Binding(get: { draft.routeChosen ? draft.route : nil },
                set: { if let r = $0 { draft.route = r; draft.routeChosen = true } })
    }

    var body: some View {
        Section {
            HStack {
                TextField("Amount", text: $draft.amountText).keyboardType(.decimalPad)
                Picker("Unit", selection: $draft.unit) {
                    ForEach(DoseUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            Picker("Route", selection: routeSelection) {
                if !draft.routeChosen { Text("Choose…").tag(AdministrationRoute?.none) }
                ForEach(routeOptions) { Text($0.displayName).tag(Optional($0)) }
            }
            .accessibilityIdentifier("routine.route")
        } header: {
            Text("Dose")
        } footer: {
            Text("Units are stored as entered and never converted automatically (for example mL is not converted to mg without a confirmed concentration, and IU is never converted).")
        }
        .vitalRow()
        Section("Schedule") {
            Picker("Frequency", selection: $draft.frequency) {
                Text("Daily").tag(FrequencyType.daily)
                Text("Every few days").tag(FrequencyType.everyNDays)
                Text("Specific days").tag(FrequencyType.weekdays)
                Text("As needed").tag(FrequencyType.asNeeded)
            }
            if draft.frequency == .everyNDays {
                Stepper("Every \(draft.intervalDays) days", value: $draft.intervalDays, in: 1...90)
            }
            if draft.frequency == .weekdays {
                WeekdayPicker(selection: $draft.weekdays)
            }
            if draft.frequency != .asNeeded {
                ForEach(draft.times.indices, id: \.self) { i in
                    DatePicker("Time \(i + 1)", selection: $draft.times[i], displayedComponents: .hourAndMinute)
                }
                .onDelete { idx in if draft.times.count > 1 { draft.times.remove(atOffsets: idx) } }
                Button("Add time") { draft.times.append(draft.times.last?.addingTimeInterval(4 * 3600) ?? Date()) }
                Toggle("Cycle (on/off days)", isOn: $draft.useCycle)
                if draft.useCycle {
                    Stepper("\(draft.cycleOn) days on", value: $draft.cycleOn, in: 1...365)
                    Stepper("\(draft.cycleOff) days off", value: $draft.cycleOff, in: 0...365)
                }
                Toggle("Keep times in \(TimeZone.current.identifier) when travelling", isOn: $draft.pinTimeZone)
                Toggle("Reminders", isOn: $draft.reminders)
            }
        }
        .vitalRow()
        Section("Dates") {
            DatePicker("Starts", selection: $draft.startDate, displayedComponents: .date)
            Toggle("Has an end date", isOn: $draft.hasEndDate)
            if draft.hasEndDate { DatePicker("Ends", selection: $draft.endDate, displayedComponents: .date) }
        }
        .vitalRow()
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack {
            ForEach(1...7, id: \.self) { d in
                let on = selection.contains(d)
                Button {
                    if on { selection.remove(d) } else { selection.insert(d) }
                } label: {
                    Text(symbols[d - 1])
                        .font(.subheadline.weight(on ? .bold : .regular))
                        .foregroundStyle(on ? VitalColors.onAccent : VitalColors.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: VitalMetrics.minTouchTarget)
                        .background(on ? VitalColors.accentStrong : VitalColors.surfaceSecondary, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}
