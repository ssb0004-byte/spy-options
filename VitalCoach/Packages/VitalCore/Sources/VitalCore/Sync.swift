import Foundation

public enum RemoteError: Error, Equatable, Sendable {
    /// Optimistic-concurrency check failed on the server (HTTP 409).
    case conflict
    /// Session missing/expired and could not be refreshed. User must sign in again.
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case network(String)
    /// Server rejected the payload (4xx other than auth/conflict). Not retried automatically.
    case invalidPayload(String)
    case notConfigured

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .network: true
        case .conflict, .unauthorized, .invalidPayload, .notConfigured: false
        }
    }
}

/// Network port for the backend. Implemented by `SupabaseRemoteStore`; faked in tests.
public protocol RemoteStore: Sendable {
    /// Inserts or updates one row; returns the stored row(s) as a JSON array.
    func upsert(_ entity: EntityName, payload: Data) async throws -> Data
    /// Rows changed after `cursor`, ordered by (server_updated_at, id), as a JSON array.
    func changes(_ entity: EntityName, after cursor: SyncCursor?, limit: Int) async throws -> Data
    /// Single row by id as a JSON array (empty if absent).
    func fetch(_ entity: EntityName, id: UUID) async throws -> Data
}

/// Keyset pagination cursor. `serverUpdatedAt` is kept as the server's exact string
/// (microsecond precision) so equality comparisons on the server are exact.
public struct SyncCursor: Sendable, Equatable {
    public var serverUpdatedAt: String
    /// nil → "everything at or after serverUpdatedAt" (used for the overlap re-read).
    public var id: UUID?

    public init(serverUpdatedAt: String, id: UUID?) { self.serverUpdatedAt = serverUpdatedAt; self.id = id }

    public var encoded: String { id.map { "\(serverUpdatedAt)|\($0.uuidString)" } ?? serverUpdatedAt }

    public init?(encoded: String) {
        let parts = encoded.split(separator: "|", maxSplits: 1).map(String.init)
        guard let first = parts.first, !first.isEmpty else { return nil }
        serverUpdatedAt = first
        id = parts.count > 1 ? UUID(uuidString: parts[1]) : nil
    }
}

public struct SyncReport: Sendable, Equatable {
    public var pushed = 0
    public var pulled = 0
    public var conflictsResolved = 0
    public var failures = 0
    public var blocked = 0
    public var needsSignIn = false
    public var finishedAt: Date?
    public init() {}
}

/// Conflict policy for mutable records: the edit with the later *client* modification time wins;
/// the loser is preserved in the conflict log. Append-only records never conflict meaningfully
/// because every change is a new row with a client-generated UUID.
public enum ConflictResolver {
    public enum Winner: Equatable, Sendable { case local, remote }

    public static func resolve(localUpdatedAt: Date, remoteUpdatedAt: Date) -> Winner {
        // Tie → remote, so all devices converge on the server's copy.
        localUpdatedAt > remoteUpdatedAt ? .local : .remote
    }
}

/// Offline-first synchronization:
/// 1. **Push** the outbox. Each upload is idempotent (client UUID + `on_conflict=id`).
///    Mutable records carry `version = knownServerVersion + 1`; the server trigger rejects
///    stale versions with 409, which triggers conflict resolution.
/// 2. **Pull** changes since a per-table cursor (server timestamp), with a small overlap
///    window to tolerate clock skew between concurrent server transactions.
/// Retries use exponential backoff; non-retryable failures are kept and surfaced, never dropped.
public actor SyncEngine {
    private let userId: UUID
    private let store: any RecordStore
    private let remote: any RemoteStore
    private let time: any TimeSource
    private var isRunning = false

    public static let pullOrder: [EntityName] = [
        .userProfiles, .userPreferences, .userGoals, .consentRecords, .healthMeasurements,
        .userSubstances, .substanceRegimens, .actualAdministrations, .adverseEffectReports,
        .symptomEntries, .painEntries, .auditEvents,
    ]
    public static let pageSize = 500
    /// Pull cursor overlap; re-reading a few rows is harmless because merges are idempotent.
    public static let cursorOverlap: TimeInterval = 120

    public init(userId: UUID, store: any RecordStore, remote: any RemoteStore, time: any TimeSource = SystemTimeSource()) {
        self.userId = userId; self.store = store; self.remote = remote; self.time = time
    }

    public static func backoff(attempts: Int) -> TimeInterval {
        min(pow(2, Double(max(attempts - 1, 0))) * 5, 3600)
    }

    public func sync() async -> SyncReport {
        var report = SyncReport()
        guard !isRunning else { return report }
        isRunning = true
        defer { isRunning = false }
        do {
            try await push(&report)
            if !report.needsSignIn { try await pull(&report) }
        } catch RemoteError.unauthorized {
            report.needsSignIn = true
        } catch {
            report.failures += 1
        }
        report.finishedAt = time.now
        return report
    }

    // MARK: Push

    func push(_ report: inout SyncReport) async throws {
        let items = try await store.outbox(userId: userId)
        for item in items where !item.isBlocked && item.nextAttemptAt <= time.now {
            do {
                if try await pushOne(item, report: &report) { report.pushed += 1 }
            } catch RemoteError.unauthorized {
                report.needsSignIn = true
                return
            } catch let e as RemoteError where e.isRetryable {
                var failed = item
                failed.attempts += 1
                failed.nextAttemptAt = time.now.addingTimeInterval(Self.backoff(attempts: failed.attempts))
                failed.lastError = String(describing: e)
                try await store.updateOutbox(failed)
                report.failures += 1
            } catch {
                var blocked = item
                blocked.isBlocked = true
                blocked.lastError = String(describing: error)
                try await store.updateOutbox(blocked)
                report.blocked += 1
            }
        }
    }

    /// Returns true when the item was uploaded.
    private func pushOne(_ item: OutboxItem, report: inout SyncReport) async throws -> Bool {
        guard let local = try await store.get(item.entity, id: item.recordId) else {
            try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
            return false
        }
        let info = try RecordRegistry.info(local)
        let outgoing = info.isAppendOnly ? local : try RecordRegistry.withVersion(local, version: info.version + 1)
        do {
            let response = try await remote.upsert(item.entity, payload: outgoing.payload)
            try await acceptServerCopy(response, item: item, fallback: outgoing)
            return true
        } catch RemoteError.conflict {
            report.conflictsResolved += 1
            return try await resolveConflict(item: item, local: local, localInfo: info, report: &report)
        }
    }

    private func acceptServerCopy(_ response: Data, item: OutboxItem, fallback: StoredEnvelope) async throws {
        let rows = (try? RecordRegistry.decodeRows(item.entity, json: response)) ?? []
        let serverVersion = try rows.first?.version ?? RecordRegistry.info(fallback).version
        // Only touch local state if the user didn't edit the record while we were uploading.
        let current = try await store.outbox(userId: userId).first { $0.key == item.key }
        if current?.generation == item.generation {
            let updated = try RecordRegistry.withVersion(fallback, version: serverVersion)
            try await store.put(updated, enqueue: nil)
            try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
        } else if let latest = try await store.get(item.entity, id: item.recordId) {
            // Keep the newer local edit queued but remember the server's version for its upload.
            try await store.put(try RecordRegistry.withVersion(latest, version: serverVersion), enqueue: nil)
        }
    }

    private func resolveConflict(item: OutboxItem, local: StoredEnvelope, localInfo: RecordRegistry.Info,
                                 report: inout SyncReport) async throws -> Bool {
        let remoteRows = try RecordRegistry.decodeRows(item.entity, json: try await remote.fetch(item.entity, id: item.recordId))
        guard let remoteRow = remoteRows.first else {
            throw RemoteError.invalidPayload("conflict reported but row not readable")
        }
        // Identical content (e.g. an earlier upload whose response was lost): just adopt it.
        if try RecordRegistry.withVersion(local, version: remoteRow.version).payload == remoteRow.envelope.payload {
            try await store.put(remoteRow.envelope, enqueue: nil)
            try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
            return true
        }
        if localInfo.isAppendOnly {
            // Same UUID already exists: an earlier upload succeeded but its response was lost.
            if remoteRow.envelope.payload != local.payload {
                try await logConflict(item: item, losing: local, winning: remoteRow.envelope, resolution: "append_only_duplicate_id")
            }
            try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
            return false
        }
        switch ConflictResolver.resolve(localUpdatedAt: localInfo.clientUpdatedAt, remoteUpdatedAt: remoteRow.clientUpdatedAt) {
        case .local:
            try await logConflict(item: item, losing: remoteRow.envelope, winning: local, resolution: "local_newer_kept")
            // Rebase onto the server version and retry once now.
            let rebased = try RecordRegistry.withVersion(local, version: remoteRow.version)
            try await store.put(rebased, enqueue: nil)
            let outgoing = try RecordRegistry.withVersion(local, version: remoteRow.version + 1)
            let response = try await remote.upsert(item.entity, payload: outgoing.payload)
            try await acceptServerCopy(response, item: item, fallback: outgoing)
            return true
        case .remote:
            try await logConflict(item: item, losing: local, winning: remoteRow.envelope, resolution: "remote_newer_kept")
            try await store.put(remoteRow.envelope, enqueue: nil)
            try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
            return false
        }
    }

    private func logConflict(item: OutboxItem, losing: StoredEnvelope, winning: StoredEnvelope, resolution: String) async throws {
        try await store.addConflict(SyncConflict(id: UUID(), entity: item.entity, recordId: item.recordId, userId: userId,
                                                 losingPayload: losing.payload, winningPayload: winning.payload,
                                                 resolvedAt: time.now, resolution: resolution))
    }

    // MARK: Pull

    func pull(_ report: inout SyncReport) async throws {
        let pending = Set(try await store.outbox(userId: userId).map(\.key))
        for entity in Self.pullOrder {
            // First page re-reads a short overlap window (concurrent server transactions can
            // commit with slightly older timestamps); later pages use exact keyset pagination.
            var cursor: SyncCursor? = try await store.cursor(entity, userId: userId)
                .flatMap(SyncCursor.init(encoded:))
                .map { c in
                    let t = ISO8601.parse(c.serverUpdatedAt).map { ISO8601.format($0.addingTimeInterval(-Self.cursorOverlap)) }
                    return SyncCursor(serverUpdatedAt: t ?? c.serverUpdatedAt, id: nil)
                }
            while true {
                let rows = try RecordRegistry.decodeRows(entity, json: try await remote.changes(entity, after: cursor, limit: Self.pageSize))
                for row in rows where row.envelope.userId == userId {
                    let key = "\(entity.rawValue)/\(row.envelope.id.uuidString)"
                    if try await merge(row, entity: entity, hasPendingLocal: pending.contains(key), report: &report) {
                        report.pulled += 1
                    }
                }
                guard let last = rows.last, let ts = last.serverUpdatedAt else { break }
                let next = SyncCursor(serverUpdatedAt: ts, id: last.envelope.id)
                try await store.setCursor(next.encoded, entity: entity, userId: userId)
                if rows.count < Self.pageSize || next == cursor { break }
                cursor = next
            }
        }
    }

    /// Returns true when local state changed.
    private func merge(_ row: RecordRegistry.Info, entity: EntityName, hasPendingLocal: Bool, report: inout SyncReport) async throws -> Bool {
        guard let existing = try await store.get(entity, id: row.envelope.id) else {
            try await store.put(row.envelope, enqueue: nil)
            return true
        }
        let local = try RecordRegistry.info(existing)
        // Echo of what we already have (or older than our pending edit's base).
        if row.version <= local.version { return false }
        if hasPendingLocal && !row.isAppendOnly {
            report.conflictsResolved += 1
            if ConflictResolver.resolve(localUpdatedAt: local.clientUpdatedAt, remoteUpdatedAt: row.clientUpdatedAt) == .local {
                // Keep local edit queued but rebase onto the server version so the push succeeds.
                try await store.put(try RecordRegistry.withVersion(existing, version: row.version), enqueue: nil)
                try await store.addConflict(SyncConflict(id: UUID(), entity: entity, recordId: row.envelope.id, userId: userId,
                                                         losingPayload: row.envelope.payload, winningPayload: existing.payload,
                                                         resolvedAt: time.now, resolution: "local_newer_kept"))
                return false
            }
            try await store.addConflict(SyncConflict(id: UUID(), entity: entity, recordId: row.envelope.id, userId: userId,
                                                     losingPayload: existing.payload, winningPayload: row.envelope.payload,
                                                     resolvedAt: time.now, resolution: "remote_newer_kept"))
            if let item = try await store.outbox(userId: userId).first(where: { $0.key == "\(entity.rawValue)/\(row.envelope.id.uuidString)" }) {
                try await store.removeOutbox(key: item.key, ifGeneration: item.generation)
            }
        }
        try await store.put(row.envelope, enqueue: nil)
        return true
    }
}
