import SwiftUI
import VitalCore

/// The seven categories offered in step 1 of Smart Routine Entry.
enum RoutineEntryCategory: String, CaseIterable, Identifiable, Hashable {
    case prescription, otc, peptide, hormone, vitaminMineral, sportsSupplement, compounded

    var id: String { rawValue }

    var category: SubstanceCategory {
        switch self {
        case .prescription: .prescription
        case .otc: .overTheCounter
        case .peptide: .peptide
        case .hormone: .hormone
        case .vitaminMineral: .vitaminMineral
        case .sportsSupplement: .sportsSupplement
        case .compounded: .compounded
        }
    }

    var title: String {
        switch self {
        case .prescription: "Prescription Medication"
        case .otc: "OTC Medication"
        case .peptide: "Peptide"
        case .hormone: "Hormone / TRT"
        case .vitaminMineral: "Vitamin / Mineral"
        case .sportsSupplement: "Sports Supplement"
        case .compounded: "Compounded Product"
        }
    }

    /// Used in "Search [Category]".
    var searchNoun: String {
        switch self {
        case .prescription: "Prescription Medications"
        case .otc: "OTC Medications"
        case .peptide: "Peptides"
        case .hormone: "Hormones"
        case .vitaminMineral: "Vitamins & Minerals"
        case .sportsSupplement: "Sports Supplements"
        case .compounded: "Compounded Products"
        }
    }

    var examples: String {
        switch self {
        case .prescription: "Metformin, Lisinopril"
        case .otc: "Ibuprofen, Cetirizine"
        case .peptide: "BPC-157, Tesamorelin"
        case .hormone: "Testosterone, Estradiol"
        case .vitaminMineral: "Vitamin D3, Magnesium"
        case .sportsSupplement: "Creatine, Whey protein"
        case .compounded: "Compounded semaglutide"
        }
    }

    var symbolName: String { category.symbolName }
}

/// Smart Routine Entry: choose a category → search the verified catalog (or add a custom name) →
/// confirm dose, route and schedule. All form state lives here, so going back and forth between
/// steps never loses what was entered.
struct AddSubstanceView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    enum Step: Hashable { case search, details }

    @State private var path: [Step] = []
    @State private var entryCategory: RoutineEntryCategory = .prescription
    @State private var query = ""
    @State private var selection: SubstanceSuggestion?
    @State private var customForm: CustomSubstanceForm.Mode?
    @State private var customNotice: String?

    // Step 3 fields (kept across steps).
    @State private var formulation = ""
    @State private var indication = ""
    @State private var isPrescribed = false
    @State private var status: SubstanceStatus = .active
    @State private var draft = RegimenDraft()
    @State private var isSaving = false

    var body: some View {
        NavigationStack(path: $path) {
            CategoryPickerView(selected: selection == nil ? nil : entryCategory) { picked in
                if picked != entryCategory, let current = selection, !(current.catalogEntry?.categories.contains(picked.category) ?? false) {
                    selection = nil
                }
                entryCategory = picked
                path.append(.search)
            }
            .navigationTitle("Add to routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .search:
                    SubstanceSearchView(category: entryCategory, query: $query, service: model.substanceSearch,
                                        onSelect: { choose($0) },
                                        onAddCustom: { customForm = .create(name: query.trimmingCharacters(in: .whitespacesAndNewlines)) })
                case .details:
                    detailsForm
                }
            }
        }
        .tint(VitalColors.accent)
        .sheet(item: $customForm) { mode in
            CustomSubstanceForm(mode: mode, defaultCategory: entryCategory.category) { saved in
                await saveCustom(saved, mode: mode)
            }
        }
    }

    // MARK: Step 3

    private var detailsForm: some View {
        Form {
            if let selection {
                Section {
                    VitalSubstanceRow(name: selection.name,
                                      detail: entryCategory.title + (selection.matchedAlias.map { " · matched “\($0)”" } ?? ""),
                                      category: entryCategory.category,
                                      origin: selection.isUserCreated ? .userCreated : .verified,
                                      note: selection.catalogEntry?.note)
                    Button("Change substance") { path.removeLast() }
                        .accessibilityIdentifier("routine.details.change")
                    if case .custom(let custom) = selection.source {
                        Button("Edit custom substance") { customForm = .edit(custom) }
                    }
                } footer: {
                    if selection.isUserCreated {
                        Text("User-created — not from the verified catalog. Check the spelling against your label or prescription. Custom names stay on this iPhone and are never added to the shared catalog.")
                    } else {
                        Text("From the verified VitalCoach catalog (\(SubstanceCatalog.version)).")
                    }
                }
            }
            if let customNotice {
                Section { NoticeBanner(style: .warning, text: customNotice) }
            }
            Section {
                TextField("Strength / form on label (optional)", text: $formulation)
                TextField("Why you take it (optional)", text: $indication)
                if entryCategory.category != .prescription {
                    Toggle("Prescribed by a clinician", isOn: $isPrescribed)
                }
                Picker("Status", selection: $status) {
                    ForEach([SubstanceStatus.active, .planned, .paused], id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            RegimenFormSection(draft: $draft, typicalRoutes: selection?.catalogEntry?.routes ?? [])
            if entryCategory.category.changesRequireClinician {
                Section {
                    NoticeBanner(style: .info, text: entryCategory == .peptide || entryCategory == .compounded
                                 ? "Enter exactly what your prescriber or the product label specifies. VitalCoach never suggests doses, schedules or cycles for peptides or compounded products."
                                 : "VitalCoach records what you and your clinician decided. It doesn't recommend doses or schedules for prescription, hormonal, peptide or compounded products.")
                }
            }
            if let msg = draft.validationMessage, !draft.amountText.isEmpty {
                Section { Label(msg, systemImage: "exclamationmark.circle").foregroundStyle(VitalColors.critical) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Dose & schedule")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(selection == nil || draft.validationMessage != nil || isSaving)
                    .accessibilityIdentifier("routine.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { hideKeyboard() }
            }
        }
    }

    // MARK: Actions

    private func choose(_ suggestion: SubstanceSuggestion) {
        let changed = selection?.id != suggestion.id
        selection = suggestion
        customNotice = nil
        if changed { applyDefaults(for: suggestion) }
        if path.last != .details { path.append(.details) }
    }

    /// Context-aware defaults. Never a dose: only the route when the catalog lists exactly one,
    /// and the label unit when nothing has been typed yet.
    private func applyDefaults(for suggestion: SubstanceSuggestion) {
        if let entry = suggestion.catalogEntry {
            if let route = entry.defaultRoute {
                draft.route = route
                draft.routeChosen = true
            } else {
                draft.routeChosen = false
            }
            if draft.amountText.isEmpty, let unit = entry.unitHint { draft.unit = unit }
        } else {
            draft.routeChosen = false
        }
        isPrescribed = entryCategory == .prescription || entryCategory == .hormone
    }

    private func saveCustom(_ form: CustomSubstanceForm.Result, mode: CustomSubstanceForm.Mode) async {
        switch mode {
        case .create:
            if let service = model.substanceSearch,
               let saved = try? await service.addCustom(name: form.name, category: form.category,
                                                        alternateName: form.alternateName, notes: form.notes) {
                adoptCustom(saved)
            } else {
                // Saving for future searches failed; manual entry still continues.
                adoptCustom(CustomSubstance(name: form.name, category: form.category, alternateName: form.alternateName, notes: form.notes))
                customNotice = "This name couldn't be saved for future searches, but you can still add it to your routine."
            }
        case .edit(let original):
            var updated = original
            updated.name = form.name; updated.category = form.category
            updated.alternateName = form.alternateName; updated.notes = form.notes
            try? await model.substanceSearch?.updateCustom(updated)
            adoptCustom(updated)
        }
    }

    private func adoptCustom(_ custom: CustomSubstance) {
        if let match = RoutineEntryCategory.allCases.first(where: { $0.category == custom.category }) { entryCategory = match }
        choose(SubstanceSuggestion(source: .custom(custom), matchedAlias: nil))
    }

    private func save() async {
        guard let userId = model.userId, let amount = draft.amount, let selection else { return }
        isSaving = true
        defer { isSaving = false }
        let cal = Calendar.current
        var aliases: [String] = []
        if let alias = selection.matchedAlias { aliases.append(alias) }
        if case .custom(let c) = selection.source, let alt = c.alternateName { aliases.append(alt) }
        var notes: String?
        if case .custom(let c) = selection.source { notes = c.notes }
        let category = entryCategory.category
        let substance = UserSubstance(userId: userId, name: String(selection.name.prefix(200)), aliases: aliases.map { String($0.prefix(200)) },
                                      category: category, formulation: formulation.nilIfBlank, indication: indication.nilIfBlank,
                                      status: status, isPrescribed: isPrescribed || category == .prescription,
                                      notes: notes.map { String($0.prefix(2000)) }, catalogRef: selection.catalogRef)
        let regimen = SubstanceRegimen(userId: userId, userSubstanceId: substance.id, dose: DoseQuantity(amount: amount, unit: draft.unit),
                                       route: draft.route, schedule: draft.schedule, startDate: LocalDate(draft.startDate, calendar: cal),
                                       endDate: draft.hasEndDate ? LocalDate(draft.endDate, calendar: cal) : nil,
                                       remindersEnabled: draft.reminders)
        await model.addSubstance(substance, regimen: regimen)
        dismiss()
    }
}

// MARK: - Step 1: category cards

struct CategoryPickerView: View {
    var selected: RoutineEntryCategory?
    var onPick: (RoutineEntryCategory) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VitalSpacing.m) {
                Text("What are you adding?")
                    .vitalFont(.section)
                    .foregroundStyle(VitalColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: VitalSpacing.s)], spacing: VitalSpacing.s) {
                    ForEach(RoutineEntryCategory.allCases) { c in
                        Button { onPick(c) } label: { card(c) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("routine.category.\(c.rawValue)")
                            .accessibilityHint("Search \(c.searchNoun.lowercased())")
                    }
                }
                Text("You'll search a verified catalog next. If your product isn't listed, you can add it as a custom substance.")
                    .vitalFont(.secondary)
                    .foregroundStyle(VitalColors.textSecondary)
            }
            .padding(VitalSpacing.page)
        }
        .vitalScreenBackground()
    }

    private func card(_ c: RoutineEntryCategory) -> some View {
        VStack(alignment: .leading, spacing: VitalSpacing.xs) {
            Image(systemName: c.symbolName)
                .font(.title3.weight(.medium))
                .foregroundStyle(VitalColors.accent)
                .frame(width: 40, height: 40)
                .background(VitalColors.accentMuted, in: RoundedRectangle(cornerRadius: VitalRadii.small, style: .continuous))
                .accessibilityHidden(true)
            Text(c.title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(c.examples).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                .lineLimit(2)
        }
        .padding(VitalSpacing.m)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(VitalColors.card, in: RoundedRectangle(cornerRadius: VitalRadii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: VitalRadii.card, style: .continuous)
                .strokeBorder(selected == c ? VitalColors.accent : VitalColors.border, lineWidth: selected == c ? 2 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: VitalRadii.card))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected == c ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Step 2: search

struct SubstanceSearchView: View {
    var category: RoutineEntryCategory
    @Binding var query: String
    var service: SubstanceAutocompleteService?
    var onSelect: (SubstanceSuggestion) -> Void
    var onAddCustom: () -> Void

    @State private var results: [SubstanceSuggestion] = []
    @State private var isSearching = false
    @FocusState private var searchFocused: Bool

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var hasExactVerifiedMatch: Bool {
        let q = SearchText.compact(trimmed)
        return results.contains { !$0.isUserCreated && SearchText.compact($0.name) == q }
    }

    var body: some View {
        List {
            if trimmed.isEmpty {
                Section {
                    Label("Type at least one letter. Brand names, generic names and abbreviations all work.", systemImage: "magnifyingglass")
                        .vitalFont(.secondary)
                        .foregroundStyle(VitalColors.textSecondary)
                }
            } else {
                Section {
                    if isSearching && results.isEmpty {
                        HStack(spacing: VitalSpacing.s) {
                            ProgressView()
                            Text("Searching…").foregroundStyle(VitalColors.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                    } else if results.isEmpty {
                        Text("No verified \(category.searchNoun.lowercased()) match “\(trimmed)”.")
                            .foregroundStyle(VitalColors.textSecondary)
                    }
                    ForEach(results) { r in
                        Button { searchFocused = false; onSelect(r) } label: {
                            VitalSubstanceRow(name: r.name,
                                              detail: r.matchedAlias.map { "Matched “\($0)”" },
                                              category: category.category,
                                              origin: r.isUserCreated ? .userCreated : .verified,
                                              note: r.catalogEntry?.note)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("routine.search.result.\(r.id)")
                    }
                }
                if !hasExactVerifiedMatch {
                    Section {
                        Button { searchFocused = false; onAddCustom() } label: {
                            Label("Add “\(trimmed)” as Custom Substance", systemImage: "plus.circle.fill")
                                .foregroundStyle(VitalColors.accentStrong)
                                .frame(minHeight: VitalMetrics.minTouchTarget, alignment: .leading)
                        }
                        .accessibilityIdentifier("routine.search.addCustom")
                    } footer: {
                        Text("Custom substances are marked as user-created and stay on this iPhone.")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(category.searchNoun)")
        .searchFocused($searchFocused)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { searchFocused = true }
        .task(id: "\(category.rawValue)|\(trimmed)") {
            guard !trimmed.isEmpty else { results = []; isSearching = false; return }
            guard let service else { results = []; isSearching = false; return }
            isSearching = true
            // Debounced: a newer keystroke cancels this task and the stale result is dropped.
            if let found = await service.debouncedSearch(trimmed, category: category.category) {
                results = found
                isSearching = false
            }
        }
    }
}

// MARK: - Custom substance form

struct CustomSubstanceForm: View {
    enum Mode: Identifiable, Hashable {
        case create(name: String)
        case edit(CustomSubstance)
        var id: String {
            switch self {
            case .create(let name): "create:\(name)"
            case .edit(let c): "edit:\(c.id)"
            }
        }
    }

    struct Result {
        var name: String
        var category: SubstanceCategory
        var alternateName: String?
        var notes: String?
    }

    var mode: Mode
    var defaultCategory: SubstanceCategory
    var onSave: (Result) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var category: SubstanceCategory = .other
    @State private var alternateName = ""
    @State private var notes = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .accessibilityIdentifier("routine.custom.name")
                    Picker("Category", selection: $category) {
                        ForEach(RoutineEntryCategory.allCases) { Text($0.title).tag($0.category) }
                        Text("Other").tag(SubstanceCategory.other)
                    }
                    TextField("Alternative name (optional)", text: $alternateName)
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                } footer: {
                    Text("Shown as “User-created” wherever it appears. It isn't checked against any reference and is never added to the shared VitalCoach catalog.")
                }
            }
            .navigationTitle(isEditing ? "Edit custom substance" : "Custom substance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEditing ? "Save" : "Continue") {
                        saving = true
                        Task {
                            await onSave(Result(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), category: category,
                                                alternateName: alternateName.nilIfBlank, notes: notes.nilIfBlank))
                            dismiss()
                        }
                    }
                    .disabled(name.nilIfBlank == nil || saving)
                    .accessibilityIdentifier("routine.custom.save")
                }
            }
            .onAppear(perform: load)
        }
        .tint(VitalColors.accent)
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private func load() {
        switch mode {
        case .create(let n):
            name = n; category = defaultCategory
        case .edit(let c):
            name = c.name; category = c.category; alternateName = c.alternateName ?? ""; notes = c.notes ?? ""
        }
    }
}

@MainActor
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
