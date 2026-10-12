import SwiftUI
import VitalCore

/// Log or correct a planned dose. Corrections never overwrite: they add a record that
/// supersedes the previous one, and the full history stays visible below.
struct DoseLogSheet: View {
    @Environment(AppModel.self) var model
    @Environment(\.dismiss) var dismiss
    var planned: PlannedDose

    @State var action: AdministrationAction = .taken
    @State var takenAt = Date()
    @State var amountText = ""
    @State var note = ""

    private var existing: ActualAdministration? {
        DoseLog.effectiveRecords(model.data.administrations).filter { $0.occurrenceKey == planned.occurrenceKey }
            .max { $0.recordedAt < $1.recordedAt }
    }

    private var history: [ActualAdministration] {
        guard let e = existing else {
            return model.data.administrations.filter { $0.occurrenceKey == planned.occurrenceKey }.sorted { $0.recordedAt < $1.recordedAt }
        }
        return DoseLog.history(of: e.id, in: model.data.administrations)
    }

    private var parsedAmount: Decimal? { DoseQuantity.parseAmount(amountText) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Scheduled", value: planned.scheduledAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Planned dose", value: "\(planned.dose.formatted), \(planned.route.displayName)")
                }
                Section(existing == nil ? "What happened?" : "Correct this entry") {
                    Picker("Outcome", selection: $action) {
                        Text("Taken").tag(AdministrationAction.taken)
                        Text("Skipped").tag(AdministrationAction.skipped)
                        Text("Missed").tag(AdministrationAction.missed)
                    }
                    .pickerStyle(.segmented)
                    if action == .taken {
                        DatePicker("Time taken", selection: $takenAt, in: ...Date())
                        HStack {
                            Text("Amount")
                            TextField(DoseQuantity.format(planned.dose.amount), text: $amountText)
                                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            Text(planned.dose.unit.displayName).foregroundStyle(.secondary)
                        }
                        if !amountText.isEmpty && parsedAmount == nil {
                            Text("Enter a positive number, e.g. 0.5 or 1/2.").font(.caption).foregroundStyle(.red)
                        }
                    }
                    TextField("Note (optional)", text: $note, axis: .vertical)
                }
                if let existing {
                    Section {
                        Button("Remove this log entry", role: .destructive) {
                            Task {
                                await model.log(.voided, planned: planned, supersedes: existing.id)
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("The slot returns to “not logged”. The original entry is kept in the history for accuracy.")
                    }
                }
                if !history.isEmpty {
                    Section("History") {
                        ForEach(history) { r in
                            VStack(alignment: .leading) {
                                Text("\(r.action.rawValue.capitalized)\(r.dose.map { " · \($0.formatted)" } ?? "")")
                                Text("Recorded \(r.recordedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(model.data.substance(planned.userSubstanceId)?.name ?? "Dose")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let dose = action == .taken ? DoseQuantity(amount: parsedAmount ?? planned.dose.amount, unit: planned.dose.unit) : nil
                            await model.log(action, planned: planned, takenAt: action == .taken ? takenAt : nil, dose: dose,
                                            note: note.isEmpty ? nil : note, supersedes: existing?.id)
                            dismiss()
                        }
                    }
                    .disabled(action == .taken && !amountText.isEmpty && parsedAmount == nil)
                }
            }
            .onAppear {
                takenAt = min(Date(), planned.scheduledAt)
                if let e = existing {
                    action = e.action == .voided ? .taken : e.action
                    takenAt = e.takenAt ?? takenAt
                    if let d = e.dose { amountText = DoseQuantity.format(d.amount) }
                    note = e.note ?? ""
                }
            }
        }
    }
}
