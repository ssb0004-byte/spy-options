import SwiftUI
import VitalCore

/// Short, adaptive check-in. Each question shows why it's being asked; unanswered questions
/// are stored as "not asked" (nil), never as zero.
struct CheckInView: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss

    @State var wellbeing: Int?
    @State var energy: Int?
    @State var clarity: Int?
    @State var stiffness: Int?
    @State var mobility = ""
    @State var sideEffects = ""
    @State var notes = ""
    @State var painItems: [PainDraft] = []
    @State var urgent: UrgentSymptomScreen.Result?

    struct PainDraft: Identifiable {
        let id = UUID()
        var location: BodyLocation = .lowerBack
        var severity = 3
        var impact: FunctionalImpact = .mild
    }

    private var plan: CheckInPlanner.Plan {
        let cal = Calendar.current
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let twoWeeks = model.today.adding(days: -14, calendar: cal) ?? model.today
        let changed = model.data.regimens.filter { $0.startDate >= twoWeeks }.count
        return CheckInPlanner.plan(.init(
            goals: Set(model.data.activeGoals), today: model.today, todayWeekday: cal.component(.weekday, from: Date()),
            weeklyCheckInWeekday: model.data.preferences?.weeklyCheckInWeekday ?? 1,
            recentPain: model.data.painEntries.filter { $0.recordedAt > weekAgo },
            recentEntries: model.data.symptomEntries.filter { $0.recordedAt > weekAgo },
            substancesStartedOrChangedWithin14Days: changed,
            openAdverseEffects: model.data.adverseEffects.filter { $0.resolvedAt == nil }.count))
    }

    var body: some View {
        let plan = self.plan
        NavigationStack {
            Form {
                if plan.isWeekly {
                    Section { Text("Weekly check-in: a few extra questions help spot longer-term changes.").font(.footnote) }
                    .vitalRow()
                }
                ForEach(plan.questions, id: \.self) { q in
                    Section {
                        question(q)
                    } footer: {
                        if let reason = plan.reasons[q] { Text(reason) }
                    }
                    .vitalRow()
                }
                if let urgent, urgent.isUrgent {
                    Section { NoticeBanner(style: .critical, text: UrgentSymptomScreen.message) }
                    .vitalRow()
                }
            }
            .vitalListBackground()
            .navigationTitle("Check-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if urgent?.isUrgent == true {
                        Button("Done") { dismiss() } // already saved; avoid a duplicate entry
                    } else {
                        Button("Save") { Task { await save(plan) } }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func question(_ q: CheckInQuestion) -> some View {
        switch q {
        case .wellbeing:
            ScaleRating(title: "Overall, how are you today?", range: 1...5, lowLabel: "Very poor", highLabel: "Excellent", value: $wellbeing)
        case .energy:
            ScaleRating(title: "Energy level", range: 1...5, lowLabel: "Exhausted", highLabel: "Very energetic", value: $energy)
        case .cognition:
            ScaleRating(title: "Mental clarity and focus", range: 1...5, lowLabel: "Very foggy", highLabel: "Very sharp", value: $clarity)
        case .stiffness:
            ScaleRating(title: "Overall stiffness", range: 0...10, lowLabel: "None", highLabel: "Worst imaginable", value: $stiffness)
        case .mobility:
            TextField("Anything you couldn't do comfortably today?", text: $mobility, axis: .vertical)
        case .pain:
            painSection
        case .sideEffects:
            TextField("Any side effects you noticed? (optional)", text: $sideEffects, axis: .vertical)
        case .notes:
            TextField("Anything else? (optional)", text: $notes, axis: .vertical)
        }
    }

    @ViewBuilder
    private var painSection: some View {
        Text("Pain").font(.subheadline.weight(.medium))
        ForEach($painItems) { $item in
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Picker("Where", selection: $item.location) {
                    ForEach(BodyLocation.allCases) { Text($0.displayName).tag($0) }
                }
                Stepper("Severity: \(item.severity) / 10", value: $item.severity, in: 0...10)
                Picker("Effect on activities", selection: $item.impact) {
                    ForEach(FunctionalImpact.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
        }
        .onDelete { painItems.remove(atOffsets: $0) }
        Button(painItems.isEmpty ? "Add pain location" : "Add another location") { painItems.append(PainDraft()) }
        if painItems.isEmpty { Text("No pain today? Leave this empty.").font(.caption).foregroundStyle(VitalColors.textSecondary) }
    }

    private func save(_ plan: CheckInPlanner.Plan) async {
        guard let userId = model.userId else { return }
        let now = Date()
        var entry = SymptomEntry(userId: userId, recordedAt: now, localDate: model.today, isWeekly: plan.isWeekly)
        entry.wellbeing = wellbeing
        entry.energy = energy
        entry.cognitiveClarity = clarity
        entry.stiffness = stiffness
        entry.mobilityLimitations = mobility.nilIfBlank
        entry.sideEffectsNote = sideEffects.nilIfBlank
        entry.note = notes.nilIfBlank
        let pain = painItems.compactMap { d in
            try? PainEntry(userId: userId, symptomEntryId: entry.id, recordedAt: now, location: d.location, severity: d.severity,
                           stiffness: stiffness, functionalImpact: d.impact)
        }
        let screen = UrgentSymptomScreen.screen(text: [notes, sideEffects, mobility].joined(separator: " "), pain: pain)
        await model.submitCheckIn(entry, pain: pain)
        if screen.isUrgent {
            urgent = screen // keep the sheet open so the safety message is seen
        } else {
            dismiss()
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
