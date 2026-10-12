import Foundation
import Testing
@testable import VitalCore

/// Produces one fully-populated JSON payload per synced entity — exactly what the app uploads.
/// `supabase/tests/run.sh` feeds these into Postgres to prove the schema accepts them.
enum SchemaFixtures {
    static let user = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let t = Date(timeIntervalSince1970: 1_780_000_000.123)

    static func all() throws -> [EntityName: Data] {
        let e = VitalJSON.encoder()
        let subst = UUID(), reg = UUID(), entry = UUID()
        var profile = UserProfile(userId: user, displayName: "Sam", clientUpdatedAt: t)
        profile.dateOfBirth = LocalDate(year: 1985, month: 4, day: 2); profile.physiologicalSex = .preferNotToSay
        profile.sexContextNote = "note"; profile.heightCm = 178.5; profile.activityLevel = .moderate
        profile.medicalConditions = ["asthma"]; profile.allergies = ["penicillin"]; profile.injuries = ["left knee"]
        profile.baselinePain = 3; profile.baselineEnergy = 3; profile.baselineMobility = 4; profile.baselineCognition = 4
        profile.onboardingCompletedAt = t
        var symptom = SymptomEntry(id: entry, userId: user, recordedAt: t, localDate: LocalDate(year: 2026, month: 5, day: 1))
        symptom.wellbeing = 4; symptom.energy = 3; symptom.cognitiveClarity = 4; symptom.stiffness = 2
        symptom.mobilityLimitations = "stairs"; symptom.sideEffectsNote = "none"; symptom.note = "ok"
        let schedule = RegimenSchedule(frequency: .weekdays, intervalDays: nil, weekdays: [2, 4], times: [LocalTime(hour: 8, minute: 0)],
                                       cycleOnDays: 5, cycleOffDays: 2, timeZoneIdentifier: "America/New_York")
        return [
            .userProfiles: try e.encode(profile),
            .userGoals: try e.encode(UserGoal(userId: user, goal: .muscleMass, priority: 1, note: "n", createdAt: t, clientUpdatedAt: t)),
            .userPreferences: try e.encode(UserPreferences(userId: user, unitSystem: .imperial, coachPersonality: .balanced, clientUpdatedAt: t)),
            .consentRecords: try e.encode(ConsentRecord(userId: user, consentType: .cloudSync, granted: true, recordedAt: t)),
            .healthMeasurements: try e.encode(HealthMeasurement(userId: user, kind: .bodyFatPercentage, value: 18.25, startAt: t, endAt: t,
                                                                sourceKind: .healthKit, sourceName: "Arboleaf", sourceBundleId: "com.example",
                                                                externalId: "HK-1", quality: .estimated, note: "n", clientUpdatedAt: t)),
            .symptomEntries: try e.encode(symptom),
            .painEntries: try e.encode(try PainEntry(userId: user, symptomEntryId: entry, recordedAt: t, location: .lowerBack, severity: 6,
                                                     stiffness: 4, functionalImpact: .moderate, locationDetail: "right side", note: "n")),
            .userSubstances: try e.encode(UserSubstance(id: subst, userId: user, name: "Vitamin D3", aliases: ["cholecalciferol"],
                                                        category: .vitaminMineral, formulation: "softgel", indication: "low level",
                                                        status: .active, isPrescribed: false, notes: "n", createdAt: t, clientUpdatedAt: t)),
            .substanceRegimens: try e.encode(SubstanceRegimen(id: reg, userId: user, userSubstanceId: subst,
                                                              dose: DoseQuantity(amount: Decimal(string: "0.125")!, unit: .milligram), route: .oral,
                                                              schedule: schedule, startDate: LocalDate(year: 2026, month: 1, day: 1),
                                                              endDate: LocalDate(year: 2026, month: 12, day: 31), supersedesId: UUID(),
                                                              changeReason: "r", concentration: DoseQuantity(amount: 200, unit: .milligram),
                                                              createdAt: t, clientUpdatedAt: t)),
            .actualAdministrations: try e.encode(ActualAdministration(userId: user, userSubstanceId: subst, regimenId: reg, occurrenceKey: "k",
                                                                      scheduledFor: t, action: .taken, takenAt: t,
                                                                      dose: DoseQuantity(amount: Decimal(string: "0.125")!, unit: .milligram),
                                                                      route: .oral, site: "s", note: "n", supersedesId: UUID(),
                                                                      timeZoneIdentifier: "America/New_York", recordedAt: t)),
            .adverseEffectReports: try e.encode(AdverseEffectReport(userId: user, userSubstanceId: subst, summary: "headache", severity: .mild,
                                                                    onsetAt: t, resolvedAt: t, note: "n", clientUpdatedAt: t)),
            .auditEvents: try e.encode(AuditEvent(userId: user, targetEntity: .userSubstances, targetId: subst, action: "status_change",
                                                  summary: "active → paused", occurredAt: t)),
        ]
    }
}

@Suite("Schema fixtures")
struct SchemaFixtureTests {
    @Test func everyEntityHasAFixtureThatRoundTrips() throws {
        let fixtures = try SchemaFixtures.all()
        #expect(Set(fixtures.keys) == Set(EntityName.allCases))
        for (entity, data) in fixtures {
            let rows = try RecordRegistry.decodeRows(entity, json: Data("[".utf8) + data + Data("]".utf8))
            #expect(rows.count == 1)
            #expect(rows[0].envelope.payload == data, "re-encoding \(entity) must be stable")
        }
        if let dir = ProcessInfo.processInfo.environment["VITALCORE_FIXTURE_DIR"] {
            for (entity, data) in fixtures {
                try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(entity.rawValue).json"))
            }
        }
    }
}

/// Decodes rows exported from Postgres (see supabase/tests/run.sh) and checks that re-encoding
/// them reproduces the exact payload the app uploaded — i.e. nothing is lost or reshaped by
/// the database (timestamps, numeric doses, dates, jsonb schedules, arrays).
@Suite("Server row decoding")
struct ServerRowDecodingTests {
    @Test func postgresRowsDecodeToTheUploadedPayload() throws {
        let env = ProcessInfo.processInfo.environment
        guard let rowsDir = env["VITALCORE_SERVER_ROWS_DIR"], let fixDir = env["VITALCORE_FIXTURE_DIR"] else { return }
        for entity in EntityName.allCases {
            let rowsData = try Data(contentsOf: URL(fileURLWithPath: rowsDir).appendingPathComponent("\(entity.rawValue).json"))
            let uploaded = try Data(contentsOf: URL(fileURLWithPath: fixDir).appendingPathComponent("\(entity.rawValue).json"))
            let rows = try RecordRegistry.decodeRows(entity, json: rowsData)
            #expect(rows.count == 1, "\(entity)")
            #expect(rows.first?.serverUpdatedAt != nil, "\(entity) server_updated_at")
            #expect(rows.first.map { String(decoding: $0.envelope.payload, as: UTF8.self) } == String(decoding: uploaded, as: UTF8.self), "\(entity)")
        }
    }
}
