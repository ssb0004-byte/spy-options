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
                    }
                }
            }
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
            Text(substance.name).font(.body.weight(.medium))
            if let r = regimen {
                Text("\(r.dose.formatted) · \(r.route.displayName) · \(ScheduleText.describe(r.schedule))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(substance.category.displayName).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Section {
            HStack {
                TextField("Amount", text: $draft.amountText).keyboardType(.decimalPad)
                Picker("Unit", selection: $draft.unit) {
                    ForEach(DoseUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
            }
            Picker("Route", selection: $draft.route) {
                ForEach(AdministrationRoute.allCases) { Text($0.displayName).tag($0) }
            }
        } header: {
            Text("Dose")
        } footer: {
            Text("Units are stored as entered and never converted automatically (for example mL is not converted to mg without a confirmed concentration, and IU is never converted).")
        }
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
        Section("Dates") {
            DatePicker("Starts", selection: $draft.startDate, displayedComponents: .date)
            Toggle("Has an end date", isOn: $draft.hasEndDate)
            if draft.hasEndDate { DatePicker("Ends", selection: $draft.endDate, displayedComponents: .date) }
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: Set<Int>

    var body: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        HStack {
            ForEach(1...7, id: \.self) { d in
                let on = selection.contains(d)
                Button(symbols[d - 1]) {
                    if on { selection.remove(d) } else { selection.insert(d) }
                }
                .buttonStyle(.bordered)
                .tint(on ? Theme.accent : .gray)
                .accessibilityLabel(Calendar.current.weekdaySymbols[d - 1])
                .accessibilityAddTraits(on ? [.isSelected] : [])
            }
        }
    }
}

struct AddSubstanceView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    @State var name = ""
    @State var category: SubstanceCategory = .vitaminMineral
    @State var formulation = ""
    @State var indication = ""
    @State var isPrescribed = false
    @State var status: SubstanceStatus = .active
    @State var draft = RegimenDraft()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Vitamin D3)", text: $name)
                    Picker("Type", selection: $category) {
                        ForEach(SubstanceCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("Formulation / strength on label (optional)", text: $formulation)
                    TextField("Why you take it (optional)", text: $indication)
                    Toggle("Prescribed by a clinician", isOn: $isPrescribed)
                    Picker("Status", selection: $status) {
                        ForEach([SubstanceStatus.active, .planned, .paused], id: \.self) { Text($0.displayName).tag($0) }
                    }
                } footer: {
                    Text("Phase 1 supports manual entry. Search, label scanning and conversational entry arrive in later updates.")
                }
                RegimenFormSection(draft: $draft)
                if category.changesRequireClinician {
                    Section {
                        NoticeBanner(style: .info, text: "VitalCoach records what you and your clinician decided. It doesn't recommend doses or schedules for prescription, hormonal, peptide or compounded products.")
                    }
                }
                if let msg = draft.validationMessage, !draft.amountText.isEmpty {
                    Section { Text(msg).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add to routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(name.nilIfBlank == nil || draft.validationMessage != nil)
                }
            }
        }
    }

    private func save() async {
        guard let userId = model.userId, let amount = draft.amount, let trimmed = name.nilIfBlank else { return }
        let cal = Calendar.current
        let substance = UserSubstance(userId: userId, name: String(trimmed.prefix(200)), category: category,
                                      formulation: formulation.nilIfBlank, indication: indication.nilIfBlank,
                                      status: status, isPrescribed: isPrescribed || category == .prescription)
        let regimen = SubstanceRegimen(userId: userId, userSubstanceId: substance.id, dose: DoseQuantity(amount: amount, unit: draft.unit),
                                       route: draft.route, schedule: draft.schedule, startDate: LocalDate(draft.startDate, calendar: cal),
                                       endDate: draft.hasEndDate ? LocalDate(draft.endDate, calendar: cal) : nil,
                                       remindersEnabled: draft.reminders)
        await model.addSubstance(substance, regimen: regimen)
        dismiss()
    }
}
