import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import VitalCore

actor RecordingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var responses: [(Int, String)]
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (code, body) = responses.isEmpty ? (200, "[]") : responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: [:])!)
    }
    func all() -> [URLRequest] { requests }
}

@Suite("Supabase client")
struct SupabaseTests {
    let config = SupabaseConfig(url: URL(string: "https://example.supabase.co")!, anonKey: "anon-public-key")
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)
    let userId = UUID()

    func tokenBody(_ token: String) -> String {
        #"{"access_token":"\#(token)","refresh_token":"r-\#(token)","expires_in":3600,"token_type":"bearer","user":{"id":"\#(userId.uuidString.lowercased())","email":"x@privaterelay.appleid.com"}}"#
    }

    @Test func configRejectsPlaceholdersAndHTTP() {
        #expect(SupabaseConfig.from(info: ["SUPABASE_URL": "https://YOUR_PROJECT.supabase.co", "SUPABASE_ANON_KEY": "k"]) == nil)
        #expect(SupabaseConfig.from(info: ["SUPABASE_URL": "http://abc.supabase.co", "SUPABASE_ANON_KEY": "k"]) == nil)
        #expect(SupabaseConfig.from(info: [:]) == nil)
        #expect(SupabaseConfig.from(info: ["SUPABASE_URL": "https://abc.supabase.co", "SUPABASE_ANON_KEY": "k"]) != nil)
    }

    @Test func appleSignInExchangesIdTokenWithRawNonce() async throws {
        let transport = RecordingTransport([(200, tokenBody("A"))])
        let storage = InMemorySessionStorage()
        let auth = SupabaseAuth(config: config, transport: transport, storage: storage, time: FixedTimeSource(t0))
        let s = try await auth.signInWithApple(idToken: "apple.jwt", rawNonce: "raw-nonce")
        #expect(s.userId == userId && s.accessToken == "A")
        #expect(await storage.load() == s)
        let req = await transport.all()[0]
        #expect(req.url?.absoluteString == "https://example.supabase.co/auth/v1/token?grant_type=id_token")
        #expect(req.value(forHTTPHeaderField: "apikey") == "anon-public-key")
        let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
        #expect(body == ["provider": "apple", "id_token": "apple.jwt", "nonce": "raw-nonce"])
    }

    @Test func refreshesExpiringTokenOnce() async throws {
        let transport = RecordingTransport([(200, tokenBody("B"))])
        let expiring = AuthSession(accessToken: "A", refreshToken: "r-A", expiresAt: t0.addingTimeInterval(30), userId: userId, email: nil)
        let auth = SupabaseAuth(config: config, transport: transport, storage: InMemorySessionStorage(expiring), time: FixedTimeSource(t0))
        #expect(try await auth.validAccessToken() == "B")
        #expect(try await auth.validAccessToken() == "B")
        #expect(await transport.all().count == 1)
    }

    @Test func failedRefreshSignsOut() async throws {
        let transport = RecordingTransport([(400, #"{"error":"invalid_grant"}"#)])
        let storage = InMemorySessionStorage(AuthSession(accessToken: "A", refreshToken: "bad", expiresAt: t0, userId: userId, email: nil))
        let auth = SupabaseAuth(config: config, transport: transport, storage: storage, time: FixedTimeSource(t0))
        await #expect(throws: RemoteError.unauthorized) { try await auth.validAccessToken() }
        #expect(await storage.load() == nil)
    }

    @Test func upsertAndKeysetQueriesAreWellFormed() async throws {
        let transport = RecordingTransport([(201, "[]"), (200, "[]"), (409, #"{"code":"PT409"}"#)])
        let session = AuthSession(accessToken: "jwt", refreshToken: "r", expiresAt: t0.addingTimeInterval(3600), userId: userId, email: nil)
        let auth = SupabaseAuth(config: config, transport: transport, storage: InMemorySessionStorage(session), time: FixedTimeSource(t0))
        let remote = SupabaseRemoteStore(config: config, transport: transport, auth: auth)
        _ = try await remote.upsert(.userGoals, payload: Data(#"{"id":"x"}"#.utf8))
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        _ = try await remote.changes(.healthMeasurements, after: SyncCursor(serverUpdatedAt: "2026-05-01T00:00:00.5+00:00", id: id), limit: 500)
        await #expect(throws: RemoteError.conflict) { try await remote.upsert(.userGoals, payload: Data("{}".utf8)) }

        let reqs = await transport.all()
        #expect(reqs[0].httpMethod == "POST")
        #expect(reqs[0].url?.absoluteString == "https://example.supabase.co/rest/v1/user_goals?on_conflict=id")
        #expect(reqs[0].value(forHTTPHeaderField: "Prefer") == "resolution=merge-duplicates,return=representation")
        #expect(reqs[0].value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
        #expect(String(decoding: reqs[0].httpBody!, as: UTF8.self) == #"[{"id":"x"}]"#)
        let q = reqs[1].url!.query!
        #expect(q.contains("order=server_updated_at.asc,id.asc"))
        #expect(q.contains("%2B00:00"))          // "+" must be escaped
        #expect(!q.contains("+"))
        #expect(q.contains("id.gt.00000000-0000-0000-0000-0000000000ab"))
    }

    @Test func statusMapping() throws {
        func resp(_ c: Int, _ h: [String: String] = [:]) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: "https://x")!, statusCode: c, httpVersion: nil, headerFields: h)! }
        #expect(throws: RemoteError.unauthorized) { try SupabaseRemoteStore.check(Data(), resp(401)) }
        #expect(throws: RemoteError.rateLimited(retryAfter: 30)) { try SupabaseRemoteStore.check(Data(), resp(429, ["Retry-After": "30"])) }
        #expect(throws: RemoteError.server(status: 503)) { try SupabaseRemoteStore.check(Data(), resp(503)) }
        #expect(throws: RemoteError.invalidPayload("HTTP 403 code 42501")) {
            try SupabaseRemoteStore.check(Data(#"{"code":"42501","message":"secret health text"}"#.utf8), resp(403))
        }
    }

    @Test func deleteAccountCallsEdgeFunction() async throws {
        let transport = RecordingTransport([(200, "{}")])
        let session = AuthSession(accessToken: "jwt", refreshToken: "r", expiresAt: t0.addingTimeInterval(3600), userId: userId, email: nil)
        let auth = SupabaseAuth(config: config, transport: transport, storage: InMemorySessionStorage(session), time: FixedTimeSource(t0))
        try await AccountService(config: config, transport: transport, auth: auth).deleteAccount()
        let req = await transport.all()[0]
        #expect(req.url?.absoluteString == "https://example.supabase.co/functions/v1/delete-account")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer jwt")
    }
}

@Suite("Adaptive logic")
struct AdaptiveTests {
    let user = UUID()
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    func ctx(goals: Set<HealthGoal>, weekday: Int = 3, pain: [PainEntry] = [], changed: Int = 0, open: Int = 0) -> CheckInPlanner.Context {
        .init(goals: goals, today: LocalDate(year: 2026, month: 5, day: 5), todayWeekday: weekday, weeklyCheckInWeekday: 1,
              recentPain: pain, recentEntries: [], substancesStartedOrChangedWithin14Days: changed, openAdverseEffects: open)
    }

    @Test func dailyCheckInIsShortWithoutReasons() {
        #expect(CheckInPlanner.plan(ctx(goals: [.fatLoss])).questions == [.wellbeing, .notes])
    }

    @Test func checkInAdaptsToGoalsAndHistory() throws {
        #expect(CheckInPlanner.plan(ctx(goals: [.reducedPain])).questions.contains(.pain))
        #expect(CheckInPlanner.plan(ctx(goals: [.cognitivePerformance])).questions.contains(.cognition))
        let pain = try PainEntry(userId: user, symptomEntryId: nil, recordedAt: t0, location: .kneeLeft, severity: 4)
        let p = CheckInPlanner.plan(ctx(goals: [.fatLoss], pain: [pain]))
        #expect(p.questions.contains(.pain) && p.questions.contains(.stiffness))
        #expect(p.reasons[.pain] == "You reported pain this week")
        #expect(CheckInPlanner.plan(ctx(goals: [], changed: 1)).questions.contains(.sideEffects))
    }

    @Test func weeklyCheckInAsksEverything() {
        let p = CheckInPlanner.plan(ctx(goals: [], weekday: 1))
        #expect(p.isWeekly && p.questions == CheckInQuestion.allCases)
    }

    @Test func painValidation() {
        #expect(throws: PainEntry.ValidationError.severityOutOfRange) { try PainEntry(userId: user, symptomEntryId: nil, recordedAt: t0, location: .head, severity: 11) }
        #expect(throws: PainEntry.ValidationError.stiffnessOutOfRange) { try PainEntry(userId: user, symptomEntryId: nil, recordedAt: t0, location: .head, severity: 3, stiffness: -1) }
    }

    @Test func onboardingRequiresConsentAndGoalsButSkipsOptional() {
        var s = OnboardingState()
        let none = ConsentState(records: [])
        s.complete(.welcome)
        #expect(s.nextStep(consents: none, hasGoals: false, healthKitAvailable: true) == .consent)
        s.skip(.consent) // required → ignored
        #expect(s.nextStep(consents: none, hasGoals: false, healthKitAvailable: true) == .consent)
        let granted = ConsentState(records: [ConsentRecord(userId: user, consentType: .termsAndAge, granted: true, recordedAt: t0)])
        s.skip(.name)
        #expect(s.nextStep(consents: granted, hasGoals: false, healthKitAvailable: true) == .goals)
        s.skip(.units); s.skip(.basics)
        #expect(s.nextStep(consents: granted, hasGoals: true, healthKitAvailable: false) == .cloudSync)
        s.skip(.cloudSync); s.complete(.coachStyle)
        #expect(s.nextStep(consents: granted, hasGoals: true, healthKitAvailable: false) == .done)
        #expect(s.deferredPrompts == [.name, .units, .basics, .cloudSync])
    }

    @Test func ageGate() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 6, day: 15))!
        #expect(AgeGate.isAdult(dateOfBirth: LocalDate(year: 2008, month: 6, day: 15), now: now, calendar: cal))
        #expect(!AgeGate.isAdult(dateOfBirth: LocalDate(year: 2008, month: 6, day: 16), now: now, calendar: cal))
    }

    @Test func consentLatestRecordWinsAndVersionMatters() {
        let grant = ConsentRecord(userId: user, consentType: .cloudSync, granted: true, recordedAt: t0)
        let withdraw = ConsentRecord(userId: user, consentType: .cloudSync, granted: false, recordedAt: t0.addingTimeInterval(10))
        #expect(ConsentState(records: [grant]).isGranted(.cloudSync))
        #expect(!ConsentState(records: [withdraw, grant]).isGranted(.cloudSync))
        #expect(!ConsentState(records: [grant]).isGranted(.aiProcessing))
        let stale = ConsentRecord(userId: user, consentType: .cloudSync, granted: true, documentVersion: 0, recordedAt: t0)
        #expect(!ConsentState(records: [stale]).isGranted(.cloudSync))
    }

    @Test func urgentSymptomScreen() throws {
        #expect(UrgentSymptomScreen.screen(text: "Sudden CHEST PAIN after dinner").isUrgent)
        #expect(UrgentSymptomScreen.screen(text: "feeling a bit tired").isUrgent == false)
        let chest = try PainEntry(userId: user, symptomEntryId: nil, recordedAt: t0, location: .chest, severity: 8)
        #expect(UrgentSymptomScreen.screen(text: nil, pain: [chest]).matched == ["severe chest pain"])
    }

    @Test func reminderPlanningIsIdempotentCappedAndDiscreet() {
        let r = regimen(user: user, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0), LocalTime(hour: 20, minute: 0)]),
                        start: LocalDate(year: 2026, month: 5, day: 1))
        let planned = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 1), to: LocalDate(year: 2026, month: 6, day: 30), deviceTimeZone: newYork)
        let now = planned[0].scheduledAt.addingTimeInterval(-60)
        let taken = ActualAdministration(userId: user, userSubstanceId: r.userSubstanceId, occurrenceKey: planned[0].occurrenceKey,
                                         action: .taken, takenAt: now, timeZoneIdentifier: "UTC", recordedAt: now)
        let reqs = ReminderPlanner.plan(planned: planned, records: [taken], names: [r.userSubstanceId: "Testosterone cypionate"],
                                        remindersEnabled: [r.id], discreet: true, now: now)
        #expect(reqs.count == ReminderPlanner.maxPending)
        #expect(reqs.first?.id == planned[1].occurrenceKey)    // already-logged dose not reminded
        #expect(!reqs[0].title.contains("Testosterone") && !reqs[0].body.contains("Testosterone"))
        let open = ReminderPlanner.plan(planned: planned, records: [], names: [r.userSubstanceId: "Magnesium"], remindersEnabled: [r.id], discreet: false, now: now)
        #expect(open[0].title == "Magnesium")
        #expect(ReminderPlanner.plan(planned: planned, records: [], names: [:], remindersEnabled: [], discreet: false, now: now).isEmpty)
    }
}

@Suite("HealthKit import")
struct HealthImportTests {
    let user = UUID()
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    func sample(_ id: String, _ kind: MetricKind = .bodyMass, _ v: Double = 80) -> ImportedSample {
        ImportedSample(externalId: id, kind: kind, value: v, startAt: t0, endAt: t0, sourceName: "Arboleaf", sourceBundleId: "com.arboleaf.app")
    }

    @Test func dedupesUpdatesAndDeletes() {
        let first = HealthImportMerger.merge(userId: user, incoming: [sample("a"), sample("b", .bodyFatPercentage, 21)], deletedExternalIds: [], existing: [], now: t0)
        #expect(first.inserted == 2)
        #expect(first.toSave.first { $0.kind == .bodyFatPercentage }?.quality == .estimated)
        #expect(first.toSave.allSatisfy { $0.sourceName == "Arboleaf" && $0.sourceKind == .healthKit })

        let again = HealthImportMerger.merge(userId: user, incoming: [sample("a")], deletedExternalIds: [], existing: first.toSave, now: t0)
        #expect(again.toSave.isEmpty) // idempotent

        let changed = HealthImportMerger.merge(userId: user, incoming: [sample("a", .bodyMass, 79.5)], deletedExternalIds: ["b"], existing: first.toSave, now: t0)
        #expect(changed.updated == 1 && changed.deleted == 1)
        let a = first.toSave.first { $0.externalId == "a" }!
        #expect(changed.toSave.first { $0.externalId == "a" }?.id == a.id) // same local record
        #expect(changed.toSave.first { $0.externalId == "b" }?.deletedAt == t0)
    }

    @Test func rejectsImplausibleAndNeverTouchesManualEntries() {
        let manual = HealthMeasurement(userId: user, kind: .bodyMass, value: 81, startAt: t0, sourceKind: .manual, externalId: "a", quality: .selfReported)
        let r = HealthImportMerger.merge(userId: user, incoming: [sample("a"), sample("x", .bodyMass, 5000)], deletedExternalIds: ["a"], existing: [manual], now: t0)
        #expect(r.rejected == 1)
        #expect(r.inserted == 1)
        #expect(!r.toSave.contains { $0.id == manual.id })
    }

    @Test func accessStatusNeverClaimsGrantWithoutData() {
        #expect(HealthAccessEvaluator.status(available: true, requested: true, hasReceivedData: false) == .requestedNoDataYet)
        #expect(HealthAccessEvaluator.status(available: true, requested: true, hasReceivedData: true) == .receivingData)
        #expect(HealthAccessEvaluator.status(available: false, requested: true, hasReceivedData: false) == .unavailable)
    }

    @Test func catalogDoesNotClaimSkeletalMuscleFromHealthKit() {
        #expect(HealthKitCatalog.entry(for: .skeletalMuscleMass) == nil)
        #expect(HealthKitCatalog.entry(for: .scaleMuscleMass) == nil)
        #expect(HealthKitCatalog.entry(for: .leanBodyMass)?.quality == .estimated)
    }
}

@Suite("Export")
struct ExportTests {
    @Test func exportIsValidJSONWithAllTables() async throws {
        let user = UUID()
        let store = InMemoryRecordStore()
        let repo = Repository(userId: user, store: store)
        _ = try await repo.save(UserGoal(userId: user, goal: .strength))
        _ = try await repo.save(SubstanceRegimen(userId: user, userSubstanceId: UUID(), dose: DoseQuantity(amount: Decimal(string: "0.25")!, unit: .milligram),
                                                 route: .oral, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]),
                                                 startDate: LocalDate(year: 2026, month: 1, day: 1)))
        let other = UUID()
        _ = try await Repository(userId: other, store: store).save(UserGoal(userId: other, goal: .fatLoss))
        let data = try await DataExporter.export(userId: user, store: store, exportedAt: Date())
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tables = obj["tables"] as! [String: [Any]]
        #expect(Set(tables.keys) == Set(EntityName.allCases.map(\.rawValue)))
        #expect(tables["user_goals"]?.count == 1) // other user's data excluded
        #expect(String(decoding: data, as: UTF8.self).contains("\"dose_amount\":0.25"))
    }
}
