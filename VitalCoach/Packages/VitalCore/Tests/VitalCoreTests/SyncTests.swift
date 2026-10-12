import Foundation
import Testing
@testable import VitalCore

/// In-memory server mimicking the Postgres behaviour defined in supabase/migrations:
/// - rows visible only to their owner (RLS),
/// - `version` must be OLD.version + 1 on update (else 409),
/// - `server_updated_at` assigned on every write, rows ordered by (server_updated_at, id).
actor FakeServer {
    struct Row { var json: [String: Any]; var serverUpdatedAt: String; var id: UUID; var userId: UUID; var version: Int }
    private var tables: [EntityName: [UUID: Row]] = [:]
    private var tick = 0
    var failNext: RemoteError?
    var dropResponseOfNextUpsert = false
    var upsertCalls = 0
    var offline = false
    func setOffline(_ v: Bool) { offline = v }
    /// When set, all writes get this exact timestamp (simulates many rows in one transaction).
    var frozenTimestamp: String?

    func setFailure(_ e: RemoteError?) { failNext = e }
    func setDropResponse() { dropResponseOfNextUpsert = true }
    func freeze(_ ts: String?) { frozenTimestamp = ts }

    private func nextTimestamp() -> String {
        if let f = frozenTimestamp { return f }
        tick += 1
        return ISO8601.format(Date(timeIntervalSince1970: 1_780_000_000 + Double(tick)))
    }

    func upsert(_ entity: EntityName, payload: Data, as user: UUID) throws -> Data {
        upsertCalls += 1
        if offline { throw RemoteError.network("offline") }
        if let e = failNext { failNext = nil; throw e }
        var obj = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
        let id = UUID(uuidString: obj["id"] as! String)!
        let owner = UUID(uuidString: obj["user_id"] as! String)!
        guard owner == user else { throw RemoteError.invalidPayload("HTTP 403 code 42501") } // RLS with check
        let version = obj["version"] as! Int
        if let existing = tables[entity]?[id] {
            guard existing.userId == user else { throw RemoteError.invalidPayload("HTTP 403 code 42501") }
            guard version == existing.version + 1 else { throw RemoteError.conflict }
        } else if version < 0 {
            throw RemoteError.invalidPayload("HTTP 400")
        }
        let ts = nextTimestamp()
        obj["server_updated_at"] = ts
        tables[entity, default: [:]][id] = Row(json: obj, serverUpdatedAt: ts, id: id, userId: owner, version: version)
        if dropResponseOfNextUpsert { dropResponseOfNextUpsert = false; throw RemoteError.network("connection lost") }
        return try JSONSerialization.data(withJSONObject: [obj])
    }

    func changes(_ entity: EntityName, after c: SyncCursor?, limit: Int, as user: UUID) throws -> Data {
        let rows = (tables[entity] ?? [:]).values.filter { $0.userId == user }
            .sorted { ($0.serverUpdatedAt, $0.id.uuidString.lowercased()) < ($1.serverUpdatedAt, $1.id.uuidString.lowercased()) }
            .filter { r in
                guard let c else { return true }
                if let cid = c.id {
                    return r.serverUpdatedAt > c.serverUpdatedAt || (r.serverUpdatedAt == c.serverUpdatedAt && r.id.uuidString.lowercased() > cid.uuidString.lowercased())
                }
                return r.serverUpdatedAt >= c.serverUpdatedAt
            }
            .prefix(limit)
        return try JSONSerialization.data(withJSONObject: rows.map(\.json))
    }

    func fetch(_ entity: EntityName, id: UUID, as user: UUID) throws -> Data {
        let rows = [tables[entity]?[id]].compactMap { $0 }.filter { $0.userId == user }
        return try JSONSerialization.data(withJSONObject: rows.map(\.json))
    }

    func count(_ entity: EntityName) -> Int { tables[entity]?.count ?? 0 }
    func version(_ entity: EntityName, _ id: UUID) -> Int? { tables[entity]?[id]?.version }
    func string(_ entity: EntityName, _ id: UUID, _ key: String) -> String? { tables[entity]?[id]?.json[key] as? String }

    /// Simulates another device editing a row directly.
    func externalEdit(_ entity: EntityName, id: UUID, set: [String: Any]) {
        guard var row = tables[entity]?[id] else { return }
        for (k, v) in set { row.json[k] = v }
        row.version += 1
        row.json["version"] = row.version
        row.serverUpdatedAt = nextTimestamp()
        row.json["server_updated_at"] = row.serverUpdatedAt
        tables[entity]?[id] = row
    }
}

/// A device: a RemoteStore bound to one signed-in user.
struct FakeRemote: RemoteStore {
    let server: FakeServer
    let user: UUID
    func upsert(_ entity: EntityName, payload: Data) async throws -> Data { try await server.upsert(entity, payload: payload, as: user) }
    func changes(_ entity: EntityName, after cursor: SyncCursor?, limit: Int) async throws -> Data { try await server.changes(entity, after: cursor, limit: limit, as: user) }
    func fetch(_ entity: EntityName, id: UUID) async throws -> Data { try await server.fetch(entity, id: id, as: user) }
}

final class MutableTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date { lock.withLock { _now } }
    func advance(_ s: TimeInterval) { lock.withLock { _now = _now.addingTimeInterval(s) } }
}

@Suite("Repository")
struct RepositoryTests {
    let user = UUID()
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func rejectsRecordsOfOtherUsers() async throws {
        let repo = Repository(userId: user, store: InMemoryRecordStore(), time: FixedTimeSource(t0))
        await #expect(throws: RepositoryError.wrongUser) {
            try await repo.save(UserGoal(userId: UUID(), goal: .strength))
        }
    }

    @Test func readsAreScopedToUser() async throws {
        let store = InMemoryRecordStore()
        let other = UUID()
        try await Repository(userId: other, store: store).save(UserGoal(userId: other, goal: .fatLoss))
        let mine = Repository(userId: user, store: store)
        try await mine.save(UserGoal(userId: user, goal: .strength))
        #expect(try await mine.all(UserGoal.self).map(\.goal) == [.strength])
        let otherGoal = try await Repository(userId: other, store: store).all(UserGoal.self)[0]
        #expect(try await mine.get(UserGoal.self, id: otherGoal.id) == nil)
    }

    @Test func appendOnlyRecordsCannotBeEditedOrDeleted() async throws {
        let repo = Repository(userId: user, store: InMemoryRecordStore(), time: FixedTimeSource(t0))
        var a = ActualAdministration(userId: user, userSubstanceId: UUID(), action: .taken, takenAt: t0, timeZoneIdentifier: "UTC", recordedAt: t0)
        a = try await repo.save(a)
        var changed = a; changed.note = "edited"
        await #expect(throws: RepositoryError.appendOnlyRecordModified) { try await repo.save(changed) }
        await #expect(throws: RepositoryError.appendOnlyRecordModified) { try await repo.delete(a) }
    }

    @Test func repeatedEditsCoalesceIntoOneUpload() async throws {
        let repo = Repository(userId: user, store: InMemoryRecordStore(), time: FixedTimeSource(t0))
        var g = try await repo.save(UserGoal(userId: user, goal: .strength))
        g.note = "a"; g = try await repo.save(g)
        g.note = "b"; g = try await repo.save(g)
        let out = try await repo.pendingUploads()
        #expect(out.count == 1 && out[0].generation == 3)
    }

    @Test func softDeleteHidesButKeepsTombstone() async throws {
        let repo = Repository(userId: user, store: InMemoryRecordStore(), time: FixedTimeSource(t0))
        let g = try await repo.save(UserGoal(userId: user, goal: .strength))
        try await repo.delete(g)
        #expect(try await repo.all(UserGoal.self).isEmpty)
        #expect(try await repo.all(UserGoal.self, includeDeleted: true).first?.deletedAt == t0)
    }
}

@Suite("Sync engine")
struct SyncEngineTests {
    let user = UUID()
    let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    func device(_ server: FakeServer, time: MutableTime) -> (Repository, SyncEngine, InMemoryRecordStore) {
        let store = InMemoryRecordStore()
        return (Repository(userId: user, store: store, time: time),
                SyncEngine(userId: user, store: store, remote: FakeRemote(server: server, user: user), time: time), store)
    }

    @Test func offlineEntriesUploadWhenOnlineAndOutboxDrains() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        let s = try await repo.save(UserSubstance(userId: user, name: "Creatine", category: .sportsSupplement))
        _ = try await repo.save(ActualAdministration(userId: user, userSubstanceId: s.id, action: .taken, takenAt: t0, timeZoneIdentifier: "UTC", recordedAt: t0))

        await server.setOffline(true)
        let r1 = await engine.sync()
        #expect(r1.failures >= 2)
        let queued = try await repo.pendingUploads()
        #expect(queued.count == 2)  // nothing discarded
        #expect(queued.allSatisfy { $0.attempts == 1 && $0.nextAttemptAt > time.now })

        await server.setOffline(false)
        time.advance(60)
        let r2 = await engine.sync()
        #expect(r2.pushed == 2)
        #expect(try await repo.pendingUploads().isEmpty)
        #expect(await server.count(.actualAdministrations) == 1)
        #expect(try await repo.get(UserSubstance.self, id: s.id)?.version == 1)
    }

    @Test func lostResponseRetryIsIdempotent() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        let a = try await repo.save(ActualAdministration(userId: user, userSubstanceId: UUID(), action: .taken, takenAt: t0, timeZoneIdentifier: "UTC", recordedAt: t0))
        await server.setDropResponse()
        _ = await engine.sync()                      // server stored it, client didn't hear back
        time.advance(60)
        let r = await engine.sync()                  // retry: same UUID → 409 handled as already-present
        #expect(r.failures == 0)
        #expect(await server.count(.actualAdministrations) == 1)
        #expect(try await repo.pendingUploads().isEmpty)
        #expect(try await repo.conflicts().isEmpty)  // identical payload → no conflict recorded
        _ = a
    }

    @Test func mutableLostResponseRebasesAndKeepsData() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        let g = try await repo.save(UserGoal(userId: user, goal: .strength, note: "v1"))
        await server.setDropResponse()
        _ = await engine.sync()
        time.advance(60)
        _ = await engine.sync()
        #expect(try await repo.pendingUploads().isEmpty)
        #expect(await server.string(.userGoals, g.id, "note") == "v1")
    }

    @Test func concurrentEditsLocalNewerWinsAndLoserIsPreserved() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        var g = try await repo.save(UserGoal(userId: user, goal: .strength, note: "original"))
        _ = await engine.sync()

        // Another device edits on the server with an older client timestamp.
        await server.externalEdit(.userGoals, id: g.id, set: ["note": "other device", "client_updated_at": ISO8601.format(t0.addingTimeInterval(10))])
        time.advance(120)
        g = try await repo.get(UserGoal.self, id: g.id)!
        g.note = "this device"
        _ = try await repo.save(g)
        let r = await engine.sync()
        #expect(r.conflictsResolved == 1)
        #expect(await server.string(.userGoals, g.id, "note") == "this device")
        let conflicts = try await repo.conflicts()
        #expect(conflicts.count == 1)
        #expect(String(decoding: conflicts[0].losingPayload, as: UTF8.self).contains("other device"))
    }

    @Test func concurrentEditsRemoteNewerWinsAndLocalIsPreserved() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        var g = try await repo.save(UserGoal(userId: user, goal: .strength, note: "original"))
        _ = await engine.sync()
        g = try await repo.get(UserGoal.self, id: g.id)!
        g.note = "offline edit"
        time.advance(10)
        _ = try await repo.save(g)
        await server.externalEdit(.userGoals, id: g.id, set: ["note": "newer remote", "client_updated_at": ISO8601.format(t0.addingTimeInterval(500))])
        _ = await engine.sync()
        #expect(try await repo.get(UserGoal.self, id: g.id)?.note == "newer remote")
        #expect(try await repo.pendingUploads().isEmpty)
        let c = try await repo.conflicts()
        #expect(c.count == 1 && c[0].resolution == "remote_newer_kept")
        #expect(String(decoding: c[0].losingPayload, as: UTF8.self).contains("offline edit"))
    }

    @Test func rejectedPayloadIsBlockedNotDiscarded() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        _ = try await repo.save(UserGoal(userId: user, goal: .energy))
        await server.setFailure(.invalidPayload("HTTP 400 code 23514"))
        let r = await engine.sync()
        #expect(r.blocked == 1)
        let out = try await repo.pendingUploads()
        #expect(out.count == 1 && out[0].isBlocked && out[0].lastError != nil)
    }

    @Test func unauthorizedStopsAndAsksForSignIn() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repo, engine, _) = device(server, time: time)
        _ = try await repo.save(UserGoal(userId: user, goal: .energy))
        await server.setFailure(.unauthorized)
        let r = await engine.sync()
        #expect(r.needsSignIn)
        #expect(try await repo.pendingUploads().count == 1)
    }

    @Test func secondDeviceReceivesEverythingIncludingDeletes() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repoA, engineA, _) = device(server, time: time)
        let (repoB, engineB, _) = device(server, time: time)
        let g = try await repoA.save(UserGoal(userId: user, goal: .longevity))
        _ = try await repoA.save(UserGoal(userId: user, goal: .mobility))
        _ = await engineA.sync()
        _ = await engineB.sync()
        #expect(try await repoB.all(UserGoal.self).count == 2)
        try await repoA.delete(try await repoA.get(UserGoal.self, id: g.id)!)
        time.advance(5)
        _ = await engineA.sync()
        _ = await engineB.sync()
        #expect(try await repoB.all(UserGoal.self).map(\.goal) == [.mobility])
    }

    @Test func pullPagesThroughRowsSharingOneTimestamp() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let (repoA, engineA, _) = device(server, time: time)
        let (repoB, engineB, _) = device(server, time: time)
        await server.freeze("2026-05-01T00:00:00.000000+00:00")
        for i in 0..<(SyncEngine.pageSize + 37) {
            _ = try await repoA.save(HealthMeasurement(userId: user, kind: .bodyMass, value: 80 + Double(i % 10) / 10,
                                                       startAt: t0.addingTimeInterval(Double(i) * 60), sourceKind: .manual, quality: .selfReported))
        }
        _ = await engineA.sync()
        let r = await engineB.sync()
        #expect(r.pulled == SyncEngine.pageSize + 37)
        #expect(try await repoB.all(HealthMeasurement.self).count == SyncEngine.pageSize + 37)
    }

    @Test func otherUsersRowsAreNeverPulled() async throws {
        let server = FakeServer(); let time = MutableTime(t0)
        let mallory = UUID()
        let mStore = InMemoryRecordStore()
        _ = try await Repository(userId: mallory, store: mStore, time: time).save(UserGoal(userId: mallory, goal: .fatLoss))
        _ = await SyncEngine(userId: mallory, store: mStore, remote: FakeRemote(server: server, user: mallory), time: time).sync()
        let (repo, engine, _) = device(server, time: time)
        _ = await engine.sync()
        #expect(try await repo.all(UserGoal.self).isEmpty)
    }

    @Test func backoffGrowsAndCaps() {
        #expect(SyncEngine.backoff(attempts: 1) == 5)
        #expect(SyncEngine.backoff(attempts: 3) == 20)
        #expect(SyncEngine.backoff(attempts: 30) == 3600)
    }

    @Test func cursorEncoding() {
        let id = UUID()
        let c = SyncCursor(serverUpdatedAt: "2026-05-01T00:00:00.123456+00:00", id: id)
        #expect(SyncCursor(encoded: c.encoded) == c)
        #expect(SyncCursor(encoded: "2026-05-01T00:00:00Z")?.id == nil)
    }
}
