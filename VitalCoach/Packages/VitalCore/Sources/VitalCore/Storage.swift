import Foundation

/// A pending upload. One item per (entity, record) — repeated edits coalesce, and
/// `generation` tells the sync engine whether the record changed while it was uploading.
public struct OutboxItem: Sendable, Equatable, Codable {
    public var entity: EntityName
    public var recordId: UUID
    public var userId: UUID
    public var enqueuedAt: Date
    public var generation: Int
    public var attempts: Int
    public var nextAttemptAt: Date
    /// Set when the server rejected the payload for a non-retryable reason. Kept (never
    /// discarded) and shown in Settings → Sync so the user can see and resolve it.
    public var lastError: String?
    public var isBlocked: Bool

    public var key: String { "\(entity.rawValue)/\(recordId.uuidString)" }

    public init(entity: EntityName, recordId: UUID, userId: UUID, enqueuedAt: Date) {
        self.entity = entity; self.recordId = recordId; self.userId = userId; self.enqueuedAt = enqueuedAt
        self.generation = 1; self.attempts = 0; self.nextAttemptAt = enqueuedAt; self.lastError = nil; self.isBlocked = false
    }
}

/// A local edit that lost a conflict. Preserved so nothing is silently discarded.
public struct SyncConflict: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var entity: EntityName
    public var recordId: UUID
    public var userId: UUID
    public var losingPayload: Data
    public var winningPayload: Data
    public var resolvedAt: Date
    public var resolution: String
}

/// Persistence port. The iOS app implements it with SwiftData; tests use `InMemoryRecordStore`.
/// Implementations must make `put(_:enqueue:)` atomic (record + outbox written together).
public protocol RecordStore: Sendable {
    func put(_ envelope: StoredEnvelope, enqueue: OutboxItem?) async throws
    func get(_ entity: EntityName, id: UUID) async throws -> StoredEnvelope?
    func all(_ entity: EntityName, userId: UUID) async throws -> [StoredEnvelope]
    func outbox(userId: UUID) async throws -> [OutboxItem]
    func updateOutbox(_ item: OutboxItem) async throws
    func removeOutbox(key: String, ifGeneration generation: Int) async throws
    func cursor(_ entity: EntityName, userId: UUID) async throws -> String?
    func setCursor(_ cursor: String, entity: EntityName, userId: UUID) async throws
    func addConflict(_ conflict: SyncConflict) async throws
    func conflicts(userId: UUID) async throws -> [SyncConflict]
    /// Removes every local record for a user (sign-out with wipe, account deletion).
    func wipe(userId: UUID) async throws
}

public actor InMemoryRecordStore: RecordStore {
    private var records: [String: StoredEnvelope] = [:]
    private var outboxItems: [String: OutboxItem] = [:]
    private var cursors: [String: String] = [:]
    private var conflictLog: [SyncConflict] = []

    public init() {}

    private func k(_ e: EntityName, _ id: UUID) -> String { "\(e.rawValue)/\(id.uuidString)" }

    public func put(_ envelope: StoredEnvelope, enqueue: OutboxItem?) async throws {
        records[k(envelope.entity, envelope.id)] = envelope
        if var item = enqueue {
            if let existing = outboxItems[item.key] {
                item.generation = existing.generation + 1
                item.enqueuedAt = existing.enqueuedAt
                item.attempts = 0
            }
            outboxItems[item.key] = item
        }
    }
    public func get(_ entity: EntityName, id: UUID) async throws -> StoredEnvelope? { records[k(entity, id)] }
    public func all(_ entity: EntityName, userId: UUID) async throws -> [StoredEnvelope] {
        records.values.filter { $0.entity == entity && $0.userId == userId }.sorted { $0.sortDate < $1.sortDate }
    }
    public func outbox(userId: UUID) async throws -> [OutboxItem] {
        outboxItems.values.filter { $0.userId == userId }.sorted { $0.enqueuedAt < $1.enqueuedAt }
    }
    public func updateOutbox(_ item: OutboxItem) async throws {
        guard let existing = outboxItems[item.key], existing.generation == item.generation else { return }
        outboxItems[item.key] = item
    }
    public func removeOutbox(key: String, ifGeneration generation: Int) async throws {
        if outboxItems[key]?.generation == generation { outboxItems[key] = nil }
    }
    public func cursor(_ entity: EntityName, userId: UUID) async throws -> String? { cursors["\(userId)/\(entity.rawValue)"] }
    public func setCursor(_ cursor: String, entity: EntityName, userId: UUID) async throws { cursors["\(userId)/\(entity.rawValue)"] = cursor }
    public func addConflict(_ conflict: SyncConflict) async throws { conflictLog.append(conflict) }
    public func conflicts(userId: UUID) async throws -> [SyncConflict] { conflictLog.filter { $0.userId == userId } }
    public func wipe(userId: UUID) async throws {
        records = records.filter { $0.value.userId != userId }
        outboxItems = outboxItems.filter { $0.value.userId != userId }
        cursors = cursors.filter { !$0.key.hasPrefix("\(userId)/") }
        conflictLog.removeAll { $0.userId == userId }
    }
}

public enum RepositoryError: Error, Equatable, Sendable {
    case wrongUser
    case appendOnlyRecordModified
}

/// The single write path for user records. Every write is local-first and enqueues an
/// upload; writes are scoped to the signed-in user.
public actor Repository {
    public let userId: UUID
    private let store: any RecordStore
    private let time: any TimeSource

    public init(userId: UUID, store: any RecordStore, time: any TimeSource = SystemTimeSource()) {
        self.userId = userId; self.store = store; self.time = time
    }

    public var now: Date { time.now }

    @discardableResult
    public func save<R: SyncableRecord>(_ record: R) async throws -> R {
        guard record.userId == userId else { throw RepositoryError.wrongUser }
        var r = record
        if let existing = try await store.get(R.entity, id: r.id) {
            let old = try existing.decode(R.self)
            if R.isAppendOnly && !old.isDeleted { throw RepositoryError.appendOnlyRecordModified }
            r.version = old.version // version is owned by sync; never regress it
            if old == r { return old }
        }
        r.clientUpdatedAt = time.now
        try await store.put(StoredEnvelope(r), enqueue: OutboxItem(entity: R.entity, recordId: r.id, userId: userId, enqueuedAt: time.now))
        return r
    }

    /// Soft delete (tombstone) so the deletion syncs. Append-only records are not deletable
    /// from the UI; corrections are made with superseding records instead.
    public func delete<R: SyncableRecord>(_ record: R) async throws {
        guard !R.isAppendOnly else { throw RepositoryError.appendOnlyRecordModified }
        var r = record
        r.deletedAt = time.now
        r.clientUpdatedAt = time.now
        guard r.userId == userId else { throw RepositoryError.wrongUser }
        if let existing = try await store.get(R.entity, id: r.id) { r.version = try existing.decode(R.self).version }
        try await store.put(StoredEnvelope(r), enqueue: OutboxItem(entity: R.entity, recordId: r.id, userId: userId, enqueuedAt: time.now))
    }

    public func all<R: SyncableRecord>(_ type: R.Type, includeDeleted: Bool = false) async throws -> [R] {
        try await store.all(R.entity, userId: userId)
            .filter { includeDeleted || !$0.isDeleted }
            .map { try $0.decode(R.self) }
    }

    public func get<R: SyncableRecord>(_ type: R.Type, id: UUID) async throws -> R? {
        guard let e = try await store.get(R.entity, id: id), e.userId == userId else { return nil }
        return try e.decode(R.self)
    }

    public func pendingUploads() async throws -> [OutboxItem] { try await store.outbox(userId: userId) }
    public func conflicts() async throws -> [SyncConflict] { try await store.conflicts(userId: userId) }

    /// Records an audit event alongside a change.
    public func audit(_ entity: EntityName, id: UUID, action: String, summary: String) async throws {
        try await save(AuditEvent(userId: userId, targetEntity: entity, targetId: id, action: action, summary: summary, occurredAt: time.now))
    }
}

// MARK: - Type registry

/// Maps entity names to concrete record types so the sync engine can handle rows generically.
/// All (de)serialization goes through `JSONEncoder`/`JSONDecoder` so `Decimal` doses stay exact.
public enum RecordRegistry {
    public struct Info: Sendable {
        public var envelope: StoredEnvelope
        public var version: Int
        public var clientUpdatedAt: Date
        public var isAppendOnly: Bool
        public var serverUpdatedAt: String?
    }

    public static func type(for entity: EntityName) -> any SyncableRecord.Type {
        switch entity {
        case .userProfiles: UserProfile.self
        case .userGoals: UserGoal.self
        case .userPreferences: UserPreferences.self
        case .consentRecords: ConsentRecord.self
        case .healthMeasurements: HealthMeasurement.self
        case .symptomEntries: SymptomEntry.self
        case .painEntries: PainEntry.self
        case .userSubstances: UserSubstance.self
        case .substanceRegimens: SubstanceRegimen.self
        case .actualAdministrations: ActualAdministration.self
        case .adverseEffectReports: AdverseEffectReport.self
        case .auditEvents: AuditEvent.self
        }
    }

    private struct ServerMeta: Decodable { var serverUpdatedAt: String? }

    /// Decodes a JSON array of rows returned by the server.
    public static func decodeRows(_ entity: EntityName, json: Data) throws -> [Info] {
        func rows<R: SyncableRecord>(_ t: R.Type) throws -> [Info] {
            let records = try VitalJSON.decoder().decode([R].self, from: json)
            let metas = try VitalJSON.decoder().decode([ServerMeta].self, from: json)
            return try zip(records, metas).map { r, m in
                Info(envelope: try StoredEnvelope(r), version: r.version, clientUpdatedAt: r.clientUpdatedAt,
                     isAppendOnly: R.isAppendOnly, serverUpdatedAt: m.serverUpdatedAt)
            }
        }
        return try rows(type(for: entity))
    }

    public static func info(_ envelope: StoredEnvelope) throws -> Info {
        func make<R: SyncableRecord>(_ t: R.Type) throws -> Info {
            let r = try envelope.decode(R.self)
            return Info(envelope: envelope, version: r.version, clientUpdatedAt: r.clientUpdatedAt, isAppendOnly: R.isAppendOnly)
        }
        return try make(type(for: envelope.entity))
    }

    /// Returns a copy of the envelope whose record has `version` replaced.
    public static func withVersion(_ envelope: StoredEnvelope, version: Int) throws -> StoredEnvelope {
        func set<R: SyncableRecord>(_ t: R.Type) throws -> StoredEnvelope {
            var r = try envelope.decode(R.self)
            r.version = version
            return try StoredEnvelope(r)
        }
        return try set(type(for: envelope.entity))
    }
}
