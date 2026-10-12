import SwiftUI
import UserNotifications
import VitalCore

struct SettingsView: View {
    @Environment(AppModel.self) var model
    @State var exportURL: URL?
    @State var confirmingDelete = false
    @State var confirmingSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section("You") {
                    NavigationLink("Profile") { ProfileEditView() }
                    NavigationLink("Goals") { GoalsEditView() }
                    if !model.onboarding.deferredPrompts.isEmpty {
                        Text("Optional details you skipped can be added in Profile.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("Preferences") {
                    NavigationLink("Units & coaching style") { PreferencesEditView() }
                    NavigationLink("Notifications") { NotificationSettingsView() }
                }
                Section("Apple Health") {
                    NavigationLink("Data sources & permissions") { HealthAccessView() }
                }
                Section("Privacy") {
                    NavigationLink("Consents") { ConsentsView() }
                    NavigationLink("Sync status") { SyncStatusView() }
                    Button("Export my data (JSON)") { Task { exportURL = await model.exportData() } }
                    if let exportURL {
                        ShareLink("Share export file", item: exportURL)
                    }
                }
                Section {
                    Button(model.isLocalOnly ? "Leave device-only mode" : "Sign out") { confirmingSignOut = true }
                    Button("Delete account and all data", role: .destructive) { confirmingDelete = true }
                } footer: {
                    Text(model.isLocalOnly ? "Device-only mode: data is stored only on this iPhone." : "Signed in with Apple.")
                }
                Section {
                    Text("VitalCoach is an educational wellness app. It doesn't diagnose, treat or prescribe. Always talk with a qualified clinician about medication decisions.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profile")
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                if !model.isLocalOnly {
                    Button("Sign out, keep data on this iPhone") { Task { await model.signOut(wipeLocalData: false) } }
                }
                Button("Sign out and remove data from this iPhone", role: .destructive) { Task { await model.signOut(wipeLocalData: true) } }
            } message: {
                Text(model.isLocalOnly ? "Device-only data is not backed up. Removing it can't be undone." :
                        (model.syncStatus.pending > 0 ? "\(model.syncStatus.pending) changes haven't synced yet. Removing local data now would lose them." : "Your synced data stays in your account."))
            }
            .confirmationDialog("Delete your account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete everything permanently", role: .destructive) { Task { _ = await model.deleteAccount() } }
            } message: {
                Text("This permanently deletes your account, your cloud records and all data on this iPhone. Data in Apple Health is not affected. Consider exporting first. This can't be undone.")
            }
        }
    }
}

struct ProfileEditView: View {
    @Environment(AppModel.self) var model
    @State var profile: UserProfile?
    @State var heightText = ""
    @State var conditions = ""
    @State var allergies = ""
    @State var injuries = ""
    @State var hasDOB = false
    @State var dob = Date()

    var body: some View {
        Form {
            if profile != nil {
                Section("Basics") {
                    TextField("Name", text: Binding(get: { profile?.displayName ?? "" }, set: { profile?.displayName = $0.nilIfBlank }))
                    Toggle("Date of birth", isOn: $hasDOB)
                    if hasDOB { DatePicker("Born", selection: $dob, in: ...Date(), displayedComponents: .date) }
                    HStack {
                        Text("Height")
                        TextField(model.data.units.length.rawValue, text: $heightText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Picker("Physiological sex", selection: Binding(get: { profile?.physiologicalSex }, set: { profile?.physiologicalSex = $0 })) {
                        Text("Not set").tag(PhysiologicalSex?.none)
                        ForEach(PhysiologicalSex.allCases, id: \.self) { Text($0.displayName).tag(PhysiologicalSex?.some($0)) }
                    }
                    TextField("Context you'd like considered (optional)", text: Binding(get: { profile?.sexContextNote ?? "" }, set: { profile?.sexContextNote = $0.nilIfBlank }))
                    Picker("Activity level", selection: Binding(get: { profile?.activityLevel }, set: { profile?.activityLevel = $0 })) {
                        Text("Not set").tag(ActivityLevel?.none)
                        ForEach(ActivityLevel.allCases, id: \.self) { Text($0.displayName).tag(ActivityLevel?.some($0)) }
                    }
                }
                Section {
                    TextField("Conditions (comma-separated)", text: $conditions, axis: .vertical)
                    TextField("Allergies (comma-separated)", text: $allergies, axis: .vertical)
                    TextField("Injuries (comma-separated)", text: $injuries, axis: .vertical)
                } header: {
                    Text("Health history (optional)")
                } footer: {
                    Text("Shared only if you choose. Used later to personalise education and safety reminders.")
                }
                if hasDOB && !AgeGate.isAdult(dateOfBirth: LocalDate(dob, calendar: .current), now: Date(), calendar: .current) {
                    NoticeBanner(style: .warning, text: "VitalCoach is only for adults 18 and older.")
                }
            }
        }
        .navigationTitle("Profile")
        .toolbar {
            Button("Save") { Task { await save() } }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard profile == nil, let p = model.data.profile else { return }
        profile = p
        heightText = p.heightCm.map { String(format: "%.1f", model.data.units.length.fromCentimeters($0)) } ?? ""
        conditions = p.medicalConditions.joined(separator: ", ")
        allergies = p.allergies.joined(separator: ", ")
        injuries = p.injuries.joined(separator: ", ")
        if let d = p.dateOfBirth?.startOfDay(in: .current) { hasDOB = true; dob = d }
    }

    private func save() async {
        guard var p = profile else { return }
        func list(_ s: String) -> [String] { s.split(separator: ",").compactMap { String($0).nilIfBlank }.map { String($0.prefix(200)) } }
        p.medicalConditions = list(conditions); p.allergies = list(allergies); p.injuries = list(injuries)
        p.dateOfBirth = hasDOB ? LocalDate(dob, calendar: .current) : nil
        if let h = Double(heightText.replacingOccurrences(of: ",", with: ".")) {
            let cm = model.data.units.length.toCentimeters(h)
            p.heightCm = (100...250).contains(cm) ? cm : p.heightCm
        } else if heightText.isEmpty { p.heightCm = nil }
        await model.save(p)
        profile = model.data.profile
    }
}

struct GoalsEditView: View {
    @Environment(AppModel.self) var model
    @State var selected: Set<HealthGoal> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text("Change your goals anytime. Past data isn't affected.").font(.callout).foregroundStyle(.secondary)
                GoalPicker(selected: $selected)
            }
            .padding()
        }
        .navigationTitle("Goals")
        .toolbar { Button("Save") { Task { await model.setGoals(selected) } }.disabled(selected.isEmpty) }
        .onAppear { selected = Set(model.data.activeGoals) }
    }
}

struct PreferencesEditView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        Form {
            if let prefs = model.data.preferences {
                Picker("Units", selection: Binding(get: { prefs.unitSystem }, set: { v in var p = prefs; p.unitSystem = v; Task { await model.save(p) } })) {
                    Text("Metric").tag(UnitSystem.metric)
                    Text("Imperial").tag(UnitSystem.imperial)
                }
                Picker("Coaching style", selection: Binding(get: { prefs.coachPersonality }, set: { v in var p = prefs; p.coachPersonality = v; Task { await model.save(p) } })) {
                    ForEach(CoachPersonality.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("Weekly check-in day", selection: Binding(get: { prefs.weeklyCheckInWeekday }, set: { v in var p = prefs; p.weeklyCheckInWeekday = v; Task { await model.save(p) } })) {
                    ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
                }
            }
        }
        .navigationTitle("Preferences")
    }
}

struct NotificationSettingsView: View {
    @Environment(AppModel.self) var model
    @State var systemStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        Form {
            if systemStatus == .denied {
                NoticeBanner(style: .warning, text: "Notifications are turned off for VitalCoach in iOS Settings, so reminders can't appear.")
            } else if systemStatus == .notDetermined {
                Button("Allow notifications") { Task { await model.notifications.requestAuthorization(); await refresh() } }
            }
            if let prefs = model.data.preferences {
                Toggle("Dose reminders", isOn: binding(prefs, \.doseReminders))
                Toggle("Hide names on lock screen", isOn: binding(prefs, \.discreetReminders))
                Toggle("Daily check-in reminder", isOn: binding(prefs, \.dailyCheckIn))
                if prefs.notifications.dailyCheckIn {
                    DatePicker("Check-in time", selection: Binding(
                        get: { Calendar.current.date(bySettingHour: prefs.notifications.checkInTime.hour, minute: prefs.notifications.checkInTime.minute, second: 0, of: Date()) ?? Date() },
                        set: { d in
                            var p = prefs
                            p.notifications.checkInTime = LocalTime(hour: Calendar.current.component(.hour, from: d), minute: Calendar.current.component(.minute, from: d))
                            Task { await model.save(p); await model.refreshReminders() }
                        }), displayedComponents: .hourAndMinute)
                }
            }
            Text("Reminders never mark a dose as taken. Use the Taken / Skip buttons on the notification or in the app.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .navigationTitle("Notifications")
        .task { await refresh() }
    }

    private func refresh() async { systemStatus = await model.notifications.authorizationStatus() }

    private func binding(_ prefs: UserPreferences, _ key: WritableKeyPath<NotificationSettings, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.notifications[keyPath: key] }, set: { v in
            var p = prefs
            p.notifications[keyPath: key] = v
            Task { await model.save(p); await model.refreshReminders() }
        })
    }
}

struct HealthAccessView: View {
    @Environment(AppModel.self) var model
    @State var importing = false

    var body: some View {
        List {
            if !model.health.isAvailable {
                NoticeBanner(style: .warning, text: "Apple Health isn't available on this device.")
            }
            Section {
                ForEach(HealthKitCatalog.entries, id: \.kind) { entry in
                    let status = model.userId.map { model.health.status(for: entry.kind, user: $0) } ?? .notRequested
                    HStack {
                        Text(entry.kind.displayName)
                        Spacer()
                        switch status {
                        case .receivingData: Label("Receiving data", systemImage: "checkmark.circle.fill").foregroundStyle(.green).labelStyle(.titleAndIcon).font(.caption)
                        case .requestedNoDataYet: Text("Requested · no data yet").font(.caption).foregroundStyle(.secondary)
                        case .notRequested:
                            Button("Connect") { Task { await model.requestHealthAccess([entry.kind]) } }.buttonStyle(.bordered)
                        case .unavailable: Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } footer: {
                Text("“No data yet” can mean access was declined or there's simply no data — iOS doesn't tell apps which. To change permissions: Settings → Health → Data Access & Devices → VitalCoach.")
            }
            Section {
                Button(importing ? "Importing…" : "Refresh from Apple Health") {
                    importing = true
                    Task { await model.importHealthData(); importing = false }
                }
                .disabled(importing)
                if let msg = model.healthImportMessage { Text(msg).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("Arboleaf scales sync to Apple Health through the Arboleaf app; VitalCoach reads them from there. Skeletal muscle mass and other scale-specific metrics that aren't in Apple Health can be entered manually.")
            }
        }
        .navigationTitle("Apple Health")
    }
}

struct ConsentsView: View {
    @Environment(AppModel.self) var model

    var body: some View {
        List {
            ForEach([ConsentType.cloudSync, .aiProcessing], id: \.self) { type in
                Section {
                    Text(type.explanation).font(.footnote)
                    Toggle(type.title, isOn: Binding(get: { model.data.consents.isGranted(type) },
                                                     set: { v in Task { await model.setConsent(type, granted: v) } }))
                    .disabled(type == .cloudSync && (model.isLocalOnly || model.backend == nil))
                } footer: {
                    if type == .aiProcessing { Text("Takes effect when the AI coach launches. Nothing is sent to an AI provider in this version.") }
                    if type == .cloudSync && model.isLocalOnly { Text("Sign in with Apple to enable backup.") }
                }
            }
            Section("Agreed") {
                LabeledContent(ConsentType.termsAndAge.title, value: model.data.consents.isGranted(.termsAndAge) ? "Yes" : "No")
            }
        }
        .navigationTitle("Consents")
    }
}

struct SyncStatusView: View {
    @Environment(AppModel.self) var model
    @State var conflicts: [SyncConflict] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Backup", value: model.canSync ? "On" : "Off")
                LabeledContent("Waiting to upload", value: "\(model.syncStatus.pending)")
                if model.syncStatus.blocked > 0 {
                    LabeledContent("Couldn't upload", value: "\(model.syncStatus.blocked)")
                }
                LabeledContent("Last sync", value: model.syncStatus.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                Button(model.syncStatus.isSyncing ? "Syncing…" : "Sync now") { Task { await model.syncNow() } }
                    .disabled(!model.canSync || model.syncStatus.isSyncing)
            } footer: {
                Text("Everything is saved on this iPhone first and uploaded when you're online. Items that couldn't upload are kept, never discarded.")
            }
            if !conflicts.isEmpty {
                Section {
                    ForEach(conflicts) { c in
                        VStack(alignment: .leading) {
                            Text(c.entity.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text("\(c.resolution.replacingOccurrences(of: "_", with: " ")) · \(c.resolvedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Edits made on two devices")
                } footer: {
                    Text("When the same item was changed in two places, the most recent edit was kept. The other version is preserved here and in your data export.")
                }
            }
        }
        .navigationTitle("Sync")
        .task { conflicts = await model.conflicts() }
    }
}
