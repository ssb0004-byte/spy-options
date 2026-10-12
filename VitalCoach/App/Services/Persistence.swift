import Foundation
import Security
@preconcurrency import SwiftData
import VitalCore

// MARK: - SwiftData models
//
// Records are stored as encoded JSON payloads plus a few indexed columns. This keeps the
// SwiftData layer tiny (and its schema stable) while all domain logic lives in VitalCore,
// where it is unit-tested. Health records are small and per-user, so in-memory filtering of
// a user's records is fast enough for Phase 1 volumes (tens of thousands of rows).

@Model
final class StoredRecord {
    /// "<entity>/<uuid>" — unique.
    @Attribute(.unique) var key: String
    var entityName: String
    var recordId: UUID
    var ownerId: UUID
    var payload: Data
    var sortDate: Date
    var indexTag: String?
    var tombstoned: Bool

    init(key: String, entityName: String, recordId: UUID, ownerId: UUID, payload: Data, sortDate: Date, indexTag: String?, tombstoned: Bool) {
        self.key = key; self.entityName = entityName; self.recordId = recordId; self.ownerId = ownerId
        self.payload = payload; self.sortDate = sortDate; self.indexTag = indexTag; self.tombstoned = tombstoned
    }
}

@Model
final class StoredOutboxItem {
    @Attribute(.unique) var key: String
    var ownerId: UUID
    var enqueuedAt: Date
    /// Encoded `OutboxItem`.
    var data: Data

    init(key: String, ownerId: UUID, enqueuedAt: Date, data: Data) {
        self.key = key; self.ownerId = ownerId; self.enqueuedAt = enqueuedAt; self.data = data
    }
}

@Model
final class StoredCursor {
    @Attribute(.unique) var key: String
    var ownerId: UUID
    var value: String

    init(key: String, ownerId: UUID, value: String) { self.key = key; self.ownerId = ownerId; self.value = value }
}

@Model
final class StoredConflict {
    var ownerId: UUID
    var resolvedAt: Date
    var data: Data

    init(ownerId: UUID, resolvedAt: Date, data: Data) { self.ownerId = ownerId; self.resolvedAt = resolvedAt; self.data = data }
}

enum PersistenceFactory {
    static var schema: Schema { Schema([StoredRecord.self, StoredOutboxItem.self, StoredCursor.self, StoredConflict.self]) }

    /// On-device store in Application Support, excluded from iCloud/iTunes backup and protected
    /// with `completeUntilFirstUserAuthentication` (encrypted at rest while the device is locked
    /// after a restart; readable after first unlock so background HealthKit delivery can write).
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        if inMemory {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }
        let fm = FileManager.default
        var dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("VitalCoach", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        let config = ModelConfiguration(schema: schema, url: dir.appendingPathComponent("records.store"), cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: config)
    }
}

/// `RecordStore` backed by SwiftData. A `@ModelActor` serializes all access on its own context.
@ModelActor
actor SwiftDataRecordStore: RecordStore {
    private static func key(_ e: EntityName, _ id: UUID) -> String { "\(e.rawValue)/\(id.uuidString)" }

    private func record(key: String) throws -> StoredRecord? {
        var d = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func outboxRow(key: String) throws -> StoredOutboxItem? {
        var d = FetchDescriptor<StoredOutboxItem>(predicate: #Predicate { $0.key == key })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    func put(_ envelope: StoredEnvelope, enqueue: OutboxItem?) async throws {
        let k = Self.key(envelope.entity, envelope.id)
        if let existing = try record(key: k) {
            existing.payload = envelope.payload
            existing.sortDate = envelope.sortDate
            existing.indexTag = envelope.indexTag
            existing.tombstoned = envelope.isDeleted
        } else {
            modelContext.insert(StoredRecord(key: k, entityName: envelope.entity.rawValue, recordId: envelope.id, ownerId: envelope.userId,
                                             payload: envelope.payload, sortDate: envelope.sortDate, indexTag: envelope.indexTag,
                                             tombstoned: envelope.isDeleted))
        }
        if var item = enqueue {
            if let row = try outboxRow(key: item.key) {
                if let old = try? JSONDecoder().decode(OutboxItem.self, from: row.data) {
                    item.generation = old.generation + 1
                    item.enqueuedAt = old.enqueuedAt
                }
                row.data = try JSONEncoder().encode(item)
            } else {
                modelContext.insert(StoredOutboxItem(key: item.key, ownerId: item.userId, enqueuedAt: item.enqueuedAt, data: try JSONEncoder().encode(item)))
            }
        }
        try modelContext.save() // record + outbox committed together
    }

    func get(_ entity: EntityName, id: UUID) async throws -> StoredEnvelope? {
        try record(key: Self.key(entity, id)).flatMap(Self.envelope)
    }

    func all(_ entity: EntityName, userId: UUID) async throws -> [StoredEnvelope] {
        let name = entity.rawValue
        let d = FetchDescriptor<StoredRecord>(predicate: #Predicate { $0.entityName == name && $0.ownerId == userId },
                                              sortBy: [SortDescriptor(\.sortDate)])
        return try modelContext.fetch(d).compactMap(Self.envelope)
    }

    private static func envelope(_ r: StoredRecord) -> StoredEnvelope? {
        guard let e = EntityName(rawValue: r.entityName) else { return nil }
        return StoredEnvelope(entity: e, id: r.recordId, userId: r.ownerId, payload: r.payload, sortDate: r.sortDate,
                              indexTag: r.indexTag, isDeleted: r.tombstoned)
    }

    func outbox(userId: UUID) async throws -> [OutboxItem] {
        let d = FetchDescriptor<StoredOutboxItem>(predicate: #Predicate { $0.ownerId == userId }, sortBy: [SortDescriptor(\.enqueuedAt)])
        return try modelContext.fetch(d).compactMap { try? JSONDecoder().decode(OutboxItem.self, from: $0.data) }
    }

    func updateOutbox(_ item: OutboxItem) async throws {
        guard let row = try outboxRow(key: item.key),
              let current = try? JSONDecoder().decode(OutboxItem.self, from: row.data),
              current.generation == item.generation else { return }
        row.data = try JSONEncoder().encode(item)
        try modelContext.save()
    }

    func removeOutbox(key: String, ifGeneration generation: Int) async throws {
        guard let row = try outboxRow(key: key),
              let current = try? JSONDecoder().decode(OutboxItem.self, from: row.data),
              current.generation == generation else { return }
        modelContext.delete(row)
        try modelContext.save()
    }

    func cursor(_ entity: EntityName, userId: UUID) async throws -> String? {
        let k = "\(userId.uuidString)/\(entity.rawValue)"
        var d = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.key == k })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first?.value
    }

    func setCursor(_ cursor: String, entity: EntityName, userId: UUID) async throws {
        let k = "\(userId.uuidString)/\(entity.rawValue)"
        var d = FetchDescriptor<StoredCursor>(predicate: #Predicate { $0.key == k })
        d.fetchLimit = 1
        if let row = try modelContext.fetch(d).first { row.value = cursor } else {
            modelContext.insert(StoredCursor(key: k, ownerId: userId, value: cursor))
        }
        try modelContext.save()
    }

    func addConflict(_ conflict: SyncConflict) async throws {
        modelContext.insert(StoredConflict(ownerId: conflict.userId, resolvedAt: conflict.resolvedAt, data: try JSONEncoder().encode(conflict)))
        try modelContext.save()
    }

    func conflicts(userId: UUID) async throws -> [SyncConflict] {
        let d = FetchDescriptor<StoredConflict>(predicate: #Predicate { $0.ownerId == userId }, sortBy: [SortDescriptor(\.resolvedAt, order: .reverse)])
        return try modelContext.fetch(d).compactMap { try? JSONDecoder().decode(SyncConflict.self, from: $0.data) }
    }

    func wipe(userId: UUID) async throws {
        try modelContext.delete(model: StoredRecord.self, where: #Predicate { $0.ownerId == userId })
        try modelContext.delete(model: StoredOutboxItem.self, where: #Predicate { $0.ownerId == userId })
        try modelContext.delete(model: StoredCursor.self, where: #Predicate { $0.ownerId == userId })
        try modelContext.delete(model: StoredConflict.self, where: #Predicate { $0.ownerId == userId })
        try modelContext.save()
    }
}

// MARK: - Keychain

/// Stores the Supabase session in the Keychain, available after first unlock and never synced
/// to other devices or included in backups (`ThisDeviceOnly`).
actor KeychainSessionStorage: SessionStorage {
    private let service = "com.vitalcoach.session"
    private let account = "supabase"

    func load() async -> AuthSession? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    func save(_ session: AuthSession?) async {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard let session, let data = try? JSONEncoder().encode(session) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
