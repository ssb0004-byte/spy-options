import SwiftUI
import VitalCore

struct SubstanceDetailView: View {
    @Environment(AppModel.self) var model
    var substanceId: UUID

    @State var showingChange = false
    @State var showingSideEffect = false
    @State var showingAsNeeded = false
    @State var correcting: PlannedDose?

    var body: some View {
        if let s = model.data.substance(substanceId) {
            content(s)
        } else {
            EmptyStateView(title: "Not found", message: "This item may have been removed on another device.", systemImage: "questionmark.circle")
        }
    }

    @ViewBuilder
    private func content(_ s: UserSubstance) -> some View {
        let cal = Calendar.current
        let current = RoutinePlanner.currentRegimen(for: s.id, regimens: model.data.regimens, on: model.today)
        let history = RoutinePlanner.history(for: s.id, regimens: model.data.regimens)
        let from = model.today.adding(days: -13, calendar: cal) ?? model.today
        let recentPlanned = history.flatMap { ScheduleGenerator.plannedDoses(for: $0, from: from, to: model.today, deviceTimeZone: .current) }
            .sorted { $0.scheduledAt > $1.scheduledAt }
        let records = model.data.administrations.filter { $0.userSubstanceId == s.id }
        let adherence = DoseLog.adherence(planned: recentPlanned, records: records, now: Date())
        let unscheduled = DoseLog.effectiveRecords(records).filter { $0.occurrenceKey == nil }.sorted { $0.sortDate > $1.sortDate }
        let effects = model.data.adverseEffects.filter { $0.userSubstanceId == s.id }.sorted { $0.onsetAt > $1.onsetAt }

        List {
            Section {
                LabeledContent("Type", value: s.category.displayName)
                LabeledContent("Status", value: s.status.displayName)
                if let f = s.formulation { LabeledContent("Formulation", value: f) }
                if let i = s.indication { LabeledContent("Reason", value: i) }
                if s.isPrescribed { LabeledContent("Prescribed", value: "Yes") }
            }
            if s.category.changesRequireClinician {
                Section {
                    NoticeBanner(style: .info, text: "Changes to prescription, hormone, peptide or compounded products should be made with your clinician. VitalCoach records changes; it doesn't recommend them.")
                }
            }
            Section("Current dose & schedule") {
                if let r = current {
                    LabeledContent("Dose", value: "\(r.dose.formatted), \(r.route.displayName)")
                    LabeledContent("Schedule", value: ScheduleText.describe(r.schedule))
                    LabeledContent("Since", value: r.startDate.description)
                    if let end = r.endDate { LabeledContent("Until", value: end.description) }
                    Button("Record a dose or schedule change") { showingChange = true }
                    if r.schedule.frequency == .asNeeded || s.status == .active {
                        Button("Log an unscheduled dose") { showingAsNeeded = true }
                    }
                } else {
                    Text("No dose recorded.").foregroundStyle(.secondary)
                }
            }
            if !recentPlanned.isEmpty {
                Section {
                    ForEach(recentPlanned.prefix(20)) { p in
                        Button { correcting = p } label: {
                            HStack {
                                Text(p.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                                Spacer()
                                StatusPill(status: DoseLog.status(of: p, records: records, now: Date()))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Last 14 days")
                } footer: {
                    Text("Taken \(adherence.taken) · skipped \(adherence.skipped) · missed \(adherence.missed) · not logged \(adherence.notLogged). Doses without a log are never counted as taken.")
                }
            }
            if !unscheduled.isEmpty {
                Section("Unscheduled doses") {
                    ForEach(unscheduled.prefix(20)) { r in
                        LabeledContent((r.takenAt ?? r.recordedAt).formatted(date: .abbreviated, time: .shortened), value: r.dose?.formatted ?? "")
                    }
                }
            }
            Section("Side effects") {
                ForEach(effects) { e in
                    VStack(alignment: .leading) {
                        Text(e.summary)
                        Text("\(e.severity.rawValue.capitalized) · since \(e.onsetAt.formatted(date: .abbreviated, time: .omitted))\(e.resolvedAt == nil ? "" : " · resolved")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if e.resolvedAt == nil {
                            Button("Resolved") {
                                var u = e; u.resolvedAt = Date()
                                Task { await model.save(u) }
                            }
                            .tint(.green)
                        }
                    }
                }
                Button("Report a side effect") { showingSideEffect = true }
            }
            if history.count > 1 {
                Section("Dose history") {
                    ForEach(history) { r in
                        VStack(alignment: .leading) {
                            Text("\(r.dose.formatted) · \(ScheduleText.describe(r.schedule))")
                            Text("\(r.startDate) → \(r.endDate?.description ?? "ongoing")\(r.changeReason.map { " · \($0)" } ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Status") {
                ForEach(SubstanceStatus.allCases.filter { $0 != s.status }, id: \.self) { st in
                    Button("Mark as \(st.displayName.lowercased())") { Task { await model.changeStatus(s, to: st) } }
                }
            }
            Section {
                Text("Research summaries and interaction screening arrive in a later update. Until then, VitalCoach makes no claims about safety or effectiveness.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(s.name)
        .sheet(isPresented: $showingChange) {
            if let r = current { ChangeRegimenView(substance: s, current: r) }
        }
        .sheet(isPresented: $showingSideEffect) { SideEffectForm(substance: s) }
        .sheet(isPresented: $showingAsNeeded) { UnscheduledDoseView(substance: s, regimen: current) }
        .sheet(item: $correcting) { p in DoseLogSheet(planned: p) }
    }
}

struct ChangeRegimenView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var substance: UserSubstance
    var current: SubstanceRegimen

    @State var draft = RegimenDraft()
    @State var reason = ""
    @State var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This starts a new dose record from the date you choose. Your previous dose stays in the history unchanged.")
                        .font(.footnote)
                    if substance.category.changesRequireClinician {
                        Text("Only record changes your clinician has made or approved.").font(.footnote.weight(.semibold))
                    }
                }
                RegimenFormSection(draft: $draft)
                Section("Reason (optional)") { TextField("e.g. Adjusted by my doctor", text: $reason) }
                if let msg = draft.validationMessage { Section { Text(msg).foregroundStyle(.red) } }
            }
            .navigationTitle("Change dose or schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount = draft.amount else { return }
                        Task {
                            await model.reviseRegimen(current, dose: DoseQuantity(amount: amount, unit: draft.unit), route: draft.route,
                                                      schedule: draft.schedule, start: LocalDate(draft.startDate, calendar: .current),
                                                      reason: reason.nilIfBlank)
                            dismiss()
                        }
                    }
                    .disabled(draft.validationMessage != nil)
                }
            }
            .onAppear {
                guard !loaded else { return }
                draft = RegimenDraft(from: current)
                loaded = true
            }
        }
    }
}

struct SideEffectForm: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var substance: UserSubstance

    @State var summary = ""
    @State var severity: AdverseEffectReport.Severity = .mild
    @State var onset = Date()
    @State var note = ""
    @State var urgent = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("What did you notice?", text: $summary, axis: .vertical)
                Picker("Severity", selection: $severity) {
                    ForEach(AdverseEffectReport.Severity.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
                DatePicker("Started", selection: $onset, in: ...Date())
                TextField("Notes (optional)", text: $note, axis: .vertical)
                Section {
                    if urgent || severity == .severe {
                        NoticeBanner(style: .critical, text: UrgentSymptomScreen.message)
                    }
                    Text("Recording a side effect doesn't mean the substance caused it. Share serious or persistent effects with your clinician or pharmacist.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Side effect")
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: summary) { _, text in urgent = UrgentSymptomScreen.screen(text: text).isUrgent }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let userId = model.userId, let text = summary.nilIfBlank else { return }
                        Task {
                            await model.save(AdverseEffectReport(userId: userId, userSubstanceId: substance.id, summary: String(text.prefix(1000)),
                                                                 severity: severity, onsetAt: onset, note: note.nilIfBlank))
                            dismiss()
                        }
                    }
                    .disabled(summary.nilIfBlank == nil)
                }
            }
        }
    }
}

struct UnscheduledDoseView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var substance: UserSubstance
    var regimen: SubstanceRegimen?

    @State var amountText = ""
    @State var unit: DoseUnit = .milligram
    @State var takenAt = Date()
    @State var note = ""

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Amount", text: $amountText).keyboardType(.decimalPad)
                    Picker("Unit", selection: $unit) {
                        ForEach(DoseUnit.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                }
                DatePicker("Taken", selection: $takenAt, in: ...Date())
                TextField("Note (optional)", text: $note)
            }
            .navigationTitle("Log a dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let amount = DoseQuantity.parseAmount(amountText) else { return }
                        Task {
                            await model.logUnscheduled(substance: substance, regimen: regimen, dose: DoseQuantity(amount: amount, unit: unit),
                                                       takenAt: takenAt, note: note.nilIfBlank)
                            dismiss()
                        }
                    }
                    .disabled(DoseQuantity.parseAmount(amountText) == nil)
                }
            }
            .onAppear {
                if let r = regimen { amountText = DoseQuantity.format(r.doseAmount); unit = r.doseUnit }
            }
        }
    }
}
