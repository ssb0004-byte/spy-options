import Foundation
import Testing
@testable import VitalCoach
import VitalCore

/// Runs the SwiftData-backed store through the same behaviours the sync engine relies on.
/// (VitalCore's own tests cover the logic with an in-memory store on any platform; these run
/// only on macOS/iOS where SwiftData exists.)
@MainActor
@Suite("SwiftData record store")
struct SwiftDataRecordStoreTests {
    func makeStore() throws -> SwiftDataRecordStore {
        SwiftDataRecordStore(modelContainer: try PersistenceFactory.makeContainer(inMemory: true))
    }

    @Test func saveReadAndIsolateUsers() async throws {
        let store = try makeStore()
        let alice = UUID(), bob = UUID()
        try await Repository(userId: alice, store: store).save(UserGoal(userId: alice, goal: .strength))
        try await Repository(userId: bob, store: store).save(UserGoal(userId: bob, goal: .fatLoss))
        #expect(try await Repository(userId: alice, store: store).all(UserGoal.self).map(\.goal) == [.strength])
        #expect(try await store.outbox(userId: alice).count == 1)
    }

    @Test func outboxCoalescesAndRespectsGeneration() async throws {
        let store = try makeStore()
        let user = UUID()
        let repo = Repository(userId: user, store: store)
        var g = try await repo.save(UserGoal(userId: user, goal: .energy))
        g.note = "x"
        _ = try await repo.save(g)
        let items = try await store.outbox(userId: user)
        #expect(items.count == 1 && items[0].generation == 2)
        try await store.removeOutbox(key: items[0].key, ifGeneration: 1) // stale generation: kept
        #expect(try await store.outbox(userId: user).count == 1)
        try await store.removeOutbox(key: items[0].key, ifGeneration: 2)
        #expect(try await store.outbox(userId: user).isEmpty)
    }

    @Test func wipeRemovesOnlyThatUser() async throws {
        let store = try makeStore()
        let a = UUID(), b = UUID()
        try await Repository(userId: a, store: store).save(UserGoal(userId: a, goal: .strength))
        try await Repository(userId: b, store: store).save(UserGoal(userId: b, goal: .strength))
        try await store.setCursor("c", entity: .userGoals, userId: a)
        try await store.wipe(userId: a)
        #expect(try await store.all(.userGoals, userId: a).isEmpty)
        #expect(try await store.cursor(.userGoals, userId: a) == nil)
        #expect(try await store.all(.userGoals, userId: b).count == 1)
    }

    @Test func decimalDosesPersistExactly() async throws {
        let store = try makeStore()
        let user = UUID()
        let repo = Repository(userId: user, store: store)
        let r = SubstanceRegimen(userId: user, userSubstanceId: UUID(), dose: DoseQuantity(amount: Decimal(string: "0.1")!, unit: .milligram),
                                 route: .subcutaneous, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]),
                                 startDate: LocalDate(year: 2026, month: 1, day: 1))
        try await repo.save(r)
        #expect(try await repo.get(SubstanceRegimen.self, id: r.id)?.doseAmount == Decimal(string: "0.1")!)
    }
}
