import Foundation
import Observation
import SwiftData
import SwiftUI
import VitalCore

/// Everything the UI shows for the signed-in user, loaded from the local store.
struct UserData {
    var profile: UserProfile?
    var preferences: UserPreferences?
    var goals: [UserGoal] = []
    var consents = ConsentState(records: [])
    var measurements: [HealthMeasurement] = []
    var substances: [UserSubstance] = []
    var regimens: [SubstanceRegimen] = []
    var administrations: [ActualAdministration] = []
    var adverseEffects: [AdverseEffectReport] = []
    var symptomEntries: [SymptomEntry] = []
    var painEntries: [PainEntry] = []

    var units: UnitSystem { preferences?.unitSystem ?? .metric }
    var activeGoals: [HealthGoal] { goals.filter(\.isActive).map(\.goal) }

    func measurements(_ kind: MetricKind) -> [HealthMeasurement] { measurements.filter { $0.kind == kind } }
    func latest(_ kind: MetricKind) -> HealthMeasurement? { SourcePreference.latest(measurements(kind)) }
    func substance(_ id: UUID) -> UserSubstance? { substances.first { $0.id == id } }
}

/// Session + application state. Views read `data` and call intent methods; all domain rules
/// live in VitalCore. Every write goes through `Repository` (local-first, queued for sync).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable { case launching, signedOut, ready }

    struct SyncStatus: Equatable {
        var lastSync: Date?
        var pending = 0
        var blocked = 0
        var conflicts = 0
        var isSyncing = false
        var message: String?
    }

    private(set) var phase: Phase = .launching
    private(set) var userId: UUID?
    private(set) var isLocalOnly = false
    private(set) var data = UserData()
    var syncStatus = SyncStatus()
    var lastError: String?
    var onboarding = OnboardingState()

    let backend: SupabaseConfig?
    let health = HealthKitService()
    let notifications = NotificationService()

    private let container: ModelContainer
    private let store: SwiftDataRecordStore
    private let auth: SupabaseAuth?
    /// AI coach API (Phase 2). nil in device-only mode or without a backend.
    private(set) var coach: CoachClient?
    var briefing: CoachInsight?
    var briefingMessage: String?
    var isLoadingBriefing = false
    /// Device-level preference (not health data), so it lives in UserDefaults.
    var briefingReminderEnabled: Bool = UserDefaults.standard.object(forKey: "coach.briefingReminder") as? Bool ?? true {
        didSet { UserDefaults.standard.set(briefingReminderEnabled, forKey: "coach.briefingReminder") }
    }
    private var repository: Repository?
    private var syncEngine: SyncEngine?
    private var syncTask: Task<Void, Never>?
    private var pendingDoseResponses: [NotificationService.DoseResponse] = []
    private let defaults = UserDefaults.standard

    init(inMemory: Bool = false) {
        var storageFailed = false
        do {
            container = try PersistenceFactory.makeContainer(inMemory: inMemory)
        } catch {
            // Fall back to memory so the app still opens; the problem is shown to the user below.
            container = try! PersistenceFactory.makeContainer(inMemory: true)
            storageFailed = true
        }
        store = SwiftDataRecordStore(modelContainer: container)
        backend = SupabaseConfig.from(info: Bundle.main.infoDictionary ?? [:])
        auth = backend.map { SupabaseAuth(config: $0, transport: URLSessionTransport(), storage: KeychainSessionStorage()) }
        if storageFailed { lastError = "Local storage could not be opened. Data entered now will not be saved." }
        notifications.onDoseResponse = { [weak self] response in
            await self?.handleDoseResponse(response)
        }
    }

    var calendar: Calendar { Calendar.current }
    var today: LocalDate { LocalDate(Date(), calendar: calendar) }

    // MARK: Session lifecycle

    func launch() async {
        if let auth, let session = await auth.currentSession() {
            await startSession(userId: session.userId, localOnly: false)
        } else if let local = defaults.string(forKey: "localOnlyUserId").flatMap(UUID.init(uuidString:)) {
            await startSession(userId: local, localOnly: true)
        } else {
            phase = .signedOut
        }
    }

    func signInWithApple(idToken: String, rawNonce: String) async {
        guard let auth else { lastError = "The backend isn't configured yet. See docs/SETUP.md."; return }
        do {
            let session = try await auth.signInWithApple(idToken: idToken, rawNonce: rawNonce)
            await startSession(userId: session.userId, localOnly: false)
        } catch {
            lastError = "Sign in failed. Please try again. (\(error.localizedDescription))"
        }
    }

    /// Device-only mode for trying the app before the backend is configured. Clearly labeled;
    /// data stays on this iPhone and is not backed up.
    func startLocalOnly() async {
        let id = UUID()
        defaults.set(id.uuidString, forKey: "localOnlyUserId")
        await startSession(userId: id, localOnly: true)
    }

    private func startSession(userId: UUID, localOnly: Bool) async {
        self.userId = userId
        isLocalOnly = localOnly
        let repo = Repository(userId: userId, store: store)
        repository = repo
        if !localOnly, let auth, let backend {
            syncEngine = SyncEngine(userId: userId, store: store,
                                    remote: SupabaseRemoteStore(config: backend, transport: URLSessionTransport(), auth: auth))
            coach = CoachClient(config: backend, transport: URLSessionTransport(), auth: auth)
        }
        onboarding = loadOnboarding(userId)
        await reload()
        if data.profile == nil {
            try? await repo.save(UserProfile(userId: userId))
            try? await repo.save(UserPreferences(userId: userId, unitSystem: Locale.current.measurementSystem == .us ? .imperial : .metric))
            await reload()
        }
        phase = .ready
        let queued = pendingDoseResponses
        pendingDoseResponses = []
        for r in queued { await handleDoseResponse(r) }
        health.startObserving { [weak self] in await self?.importHealthData() }
        await refreshReminders()
        scheduleSync(after: 0)
    }

    func signOut(wipeLocalData: Bool) async {
        guard let userId else { return }
        health.stopObserving()
        notifications.removeAll()
        if wipeLocalData {
            try? await store.wipe(userId: userId)
            health.resetAnchors(user: userId)
            defaults.removeObject(forKey: onboardingKey(userId))
        }
        await auth?.signOut()
        if isLocalOnly { defaults.removeObject(forKey: "localOnlyUserId") }
        resetSessionState()
    }

    /// Deletes the server account (if any), then all local data. Irreversible.
    func deleteAccount() async -> Bool {
        guard let userId else { return false }
        if !isLocalOnly, let backend, let auth {
            do {
                try await AccountService(config: backend, transport: URLSessionTransport(), auth: auth).deleteAccount()
            } catch {
                lastError = "Account deletion failed and nothing was deleted. Check your connection and try again."
                return false
            }
        }
        health.stopObserving()
        notifications.removeAll()
        try? await store.wipe(userId: userId)
        health.resetAnchors(user: userId)
        defaults.removeObject(forKey: onboardingKey(userId))
        defaults.removeObject(forKey: "localOnlyUserId")
        await auth?.signOut()
        resetSessionState()
        return true
    }

    private func resetSessionState() {
        syncTask?.cancel()
        repository = nil; syncEngine = nil; userId = nil; isLocalOnly = false
        coach = nil; briefing = nil; briefingMessage = nil
        data = UserData(); syncStatus = SyncStatus(); onboarding = OnboardingState()
        phase = .signedOut
    }

    // MARK: Loading

    func reload() async {
        guard let repo = repository else { return }
        do {
            var d = UserData()
            d.profile = try await repo.all(UserProfile.self).first
            d.preferences = try await repo.all(UserPreferences.self).first
            d.goals = try await repo.all(UserGoal.self)
            d.consents = ConsentState(records: try await repo.all(ConsentRecord.self))
            d.measurements = try await repo.all(HealthMeasurement.self)
            d.substances = try await repo.all(UserSubstance.self)
            d.regimens = try await repo.all(SubstanceRegimen.self)
            d.administrations = try await repo.all(ActualAdministration.self)
            d.adverseEffects = try await repo.all(AdverseEffectReport.self)
            d.symptomEntries = try await repo.all(SymptomEntry.self)
            d.painEntries = try await repo.all(PainEntry.self)
            data = d
            let pending = try await repo.pendingUploads()
            syncStatus.pending = pending.count
            syncStatus.blocked = pending.filter(\.isBlocked).count
            syncStatus.conflicts = try await repo.conflicts().count
        } catch {
            lastError = "Couldn't load your data: \(error.localizedDescription)"
        }
    }

    // MARK: Writes

    /// Saves records, records an audit event when given, reloads and schedules a sync.
    func perform(_ label: String, _ work: (Repository) async throws -> Void) async {
        guard let repo = repository else { return }
        do {
            try await work(repo)
            await reload()
            scheduleSync(after: 2)
        } catch {
            lastError = "\(label) failed: \(error.localizedDescription)"
        }
    }

    func save<R: SyncableRecord>(_ record: R) async {
        await perform("Saving") { try await $0.save(record) }
    }

    func setConsent(_ type: ConsentType, granted: Bool) async {
        guard let userId else { return }
        await perform("Updating consent") { repo in
            try await repo.save(ConsentRecord(userId: userId, consentType: type, granted: granted, recordedAt: Date()))
        }
        if type == .cloudSync && granted { scheduleSync(after: 0) }
    }

    func setGoals(_ selected: Set<HealthGoal>) async {
        guard let userId else { return }
        let existing = data.goals
        await perform("Updating goals") { repo in
            for g in existing where !selected.contains(g.goal) && g.isActive {
                var updated = g; updated.isActive = false
                try await repo.save(updated)
            }
            for goal in selected {
                if var g = existing.first(where: { $0.goal == goal }) {
                    if !g.isActive { g.isActive = true; try await repo.save(g) }
                } else {
                    try await repo.save(UserGoal(userId: userId, goal: goal))
                }
            }
        }
    }

    func addSubstance(_ substance: UserSubstance, regimen: SubstanceRegimen?) async {
        await perform("Adding to routine") { repo in
            try await repo.save(substance)
            if let regimen { try await repo.save(regimen) }
            try await repo.audit(.userSubstances, id: substance.id, action: "create", summary: "added (\(substance.category.rawValue))")
        }
        await refreshReminders()
    }

    func changeStatus(_ substance: UserSubstance, to status: SubstanceStatus) async {
        var s = substance
        let old = s.status
        s.status = status
        await perform("Updating status") { repo in
            try await repo.save(s)
            try await repo.audit(.userSubstances, id: s.id, action: "status_change", summary: "\(old.rawValue) → \(status.rawValue)")
            // Ending a substance also ends its open regimen today, preserving history.
            if status == .completed || status == .discontinued {
                for var r in self.data.regimens where r.userSubstanceId == s.id && r.endDate == nil {
                    r.endDate = self.today
                    try await repo.save(r)
                }
            }
        }
        await refreshReminders()
    }

    func reviseRegimen(_ current: SubstanceRegimen, dose: DoseQuantity, route: AdministrationRoute, schedule: RegimenSchedule,
                       start: LocalDate, reason: String?) async {
        let (ended, successor) = RegimenHistory.revise(current, newDose: dose, newRoute: route, newSchedule: schedule,
                                                       newStart: start, reason: reason, now: Date(), calendar: calendar)
        await perform("Updating dose or schedule") { repo in
            try await repo.save(ended)
            try await repo.save(successor)
            try await repo.audit(.substanceRegimens, id: successor.id, action: "regimen_change",
                                 summary: "\(current.dose.formatted) → \(dose.formatted), from \(start)")
        }
        await refreshReminders()
    }

    func log(_ action: AdministrationAction, planned: PlannedDose, takenAt: Date? = nil, dose: DoseQuantity? = nil,
             note: String? = nil, supersedes: UUID? = nil) async {
        guard let userId else { return }
        let record = RoutinePlanner.log(action, planned: planned, userId: userId, at: Date(), timeZone: .current,
                                        takenAt: takenAt, dose: dose, note: note, supersedes: supersedes)
        await perform("Logging dose") { repo in
            try await repo.save(record)
            if supersedes != nil {
                try await repo.audit(.actualAdministrations, id: record.id, action: "correction", summary: "corrected to \(action.rawValue)")
            }
        }
        await refreshReminders()
    }

    /// Logs an unscheduled / as-needed dose.
    func logUnscheduled(substance: UserSubstance, regimen: SubstanceRegimen?, dose: DoseQuantity, takenAt: Date, note: String?) async {
        guard let userId else { return }
        let record = ActualAdministration(userId: userId, userSubstanceId: substance.id, regimenId: regimen?.id, action: .taken,
                                          takenAt: takenAt, dose: dose, route: regimen?.route, note: note,
                                          timeZoneIdentifier: TimeZone.current.identifier, recordedAt: Date())
        await perform("Logging dose") { try await $0.save(record) }
    }

    private func handleDoseResponse(_ r: NotificationService.DoseResponse) async {
        guard phase == .ready else { pendingDoseResponses.append(r); return }
        let day = LocalDate(r.scheduledAt, calendar: calendar)
        let planned = RoutinePlanner.planned(substances: data.substances, regimens: data.regimens, from: day, to: day, deviceTimeZone: .current)
            .first { $0.occurrenceKey == r.occurrenceKey }
        guard let planned else { return }
        await log(r.taken ? .taken : .skipped, planned: planned)
    }

    func addMeasurement(kind: MetricKind, displayValue: Double, at date: Date, note: String?) async -> String? {
        guard let userId else { return nil }
        do {
            let m = try MeasurementFactory.manual(userId: userId, kind: kind, displayValue: displayValue, units: data.units, at: date, now: Date(), note: note)
            await save(m)
            return nil
        } catch MeasurementValidationError.outOfRange(_, let range) {
            let lo = MetricDisplay.format(range.lowerBound, kind: kind, units: data.units)
            let hi = MetricDisplay.format(range.upperBound, kind: kind, units: data.units)
            return "That value looks unlikely. Expected between \(lo) and \(hi)."
        } catch MeasurementValidationError.futureDate {
            return "The date can't be in the future."
        } catch {
            return "Please enter a valid number."
        }
    }

    func deleteMeasurement(_ m: HealthMeasurement) async {
        await perform("Deleting measurement") { repo in
            try await repo.delete(m)
            try await repo.audit(.healthMeasurements, id: m.id, action: "delete", summary: "\(m.kind.rawValue) deleted")
        }
    }

    func submitCheckIn(_ entry: SymptomEntry, pain: [PainEntry]) async {
        await perform("Saving check-in") { repo in
            try await repo.save(entry)
            for p in pain { try await repo.save(p) }
        }
    }

    // MARK: HealthKit

    func requestHealthAccess(_ kinds: [MetricKind]) async {
        do {
            try await health.requestAccess(for: kinds)
            health.startObserving { [weak self] in await self?.importHealthData() }
            await importHealthData()
        } catch {
            lastError = "Apple Health access request failed: \(error.localizedDescription)"
        }
    }

    var healthImportMessage: String?

    func importHealthData() async {
        guard let repo = repository, let userId else { return }
        let s = await health.importAll(user: userId, repository: repo)
        healthImportMessage = s.errors.isEmpty
            ? "Apple Health: \(s.inserted) new, \(s.updated) updated, \(s.deleted) removed."
            : "Some Apple Health data couldn't be read: " + s.errors.joined(separator: "; ")
        await reload()
        scheduleSync(after: 2)
    }

    // MARK: Reminders

    func refreshReminders() async {
        guard let prefs = data.preferences else { return }
        await notifications.scheduleDailyCheckIn(enabled: prefs.notifications.dailyCheckIn, at: prefs.notifications.checkInTime)
        await notifications.scheduleMorningBriefing(enabled: coachAvailability == .ready && briefingReminderEnabled,
                                                    at: briefingReminderTime)
        guard prefs.notifications.doseReminders, let end = today.adding(days: 14, calendar: calendar) else {
            await notifications.replaceDoseReminders([], plannedById: [:])
            return
        }
        let planned = RoutinePlanner.planned(substances: data.substances, regimens: data.regimens, from: today, to: end, deviceTimeZone: .current)
        let names = Dictionary(data.substances.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let enabled = Set(data.regimens.filter(\.remindersEnabled).map(\.id))
        let reminders = ReminderPlanner.plan(planned: planned, records: data.administrations, names: names, remindersEnabled: enabled,
                                             discreet: prefs.notifications.discreetReminders, now: Date())
        await notifications.replaceDoseReminders(reminders, plannedById: Dictionary(planned.map { ($0.occurrenceKey, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: Sync

    var canSync: Bool { syncEngine != nil && data.consents.isGranted(.cloudSync) }

    func scheduleSync(after seconds: Double) {
        guard canSync else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard canSync, let engine = syncEngine, !syncStatus.isSyncing else { return }
        syncStatus.isSyncing = true
        let report = await engine.sync()
        syncStatus.isSyncing = false
        syncStatus.lastSync = report.finishedAt
        syncStatus.message = report.needsSignIn ? "Your session expired. Sign in again to resume syncing."
            : report.failures > 0 ? "Some changes couldn't sync yet. They're saved on this iPhone and will retry automatically."
            : nil
        await reload()
        if report.pulled > 0 { await refreshReminders() }
    }

    func conflicts() async -> [SyncConflict] { (try? await repository?.conflicts()) ?? [] }

    // MARK: Export

    func exportData() async -> URL? {
        guard let userId else { return nil }
        do {
            let data = try await DataExporter.export(userId: userId, store: store, exportedAt: Date())
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("VitalCoach-export-\(today).json")
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            return url
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Onboarding persistence (UI progress only; not health data)

    private func onboardingKey(_ id: UUID) -> String { "onboarding.\(id.uuidString)" }

    private func loadOnboarding(_ id: UUID) -> OnboardingState {
        defaults.data(forKey: onboardingKey(id)).flatMap { try? JSONDecoder().decode(OnboardingState.self, from: $0) } ?? OnboardingState()
    }

    func saveOnboarding() {
        guard let userId, let d = try? JSONEncoder().encode(onboarding) else { return }
        defaults.set(d, forKey: onboardingKey(userId))
    }

    var nextOnboardingStep: OnboardingStep {
        onboarding.nextStep(consents: data.consents, hasGoals: !data.activeGoals.isEmpty, healthKitAvailable: health.isAvailable)
    }

    var needsOnboarding: Bool { data.profile?.onboardingCompletedAt == nil }

    func finishOnboarding() async {
        guard var p = data.profile else { return }
        p.onboardingCompletedAt = Date()
        await save(p)
        saveOnboarding()
    }
}
