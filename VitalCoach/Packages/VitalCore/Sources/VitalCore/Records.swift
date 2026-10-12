import Foundation

/// Name of a synchronized entity. The raw value is the Supabase table name.
public enum EntityName: String, Codable, Sendable, CaseIterable {
    case userProfiles = "user_profiles"
    case userGoals = "user_goals"
    case userPreferences = "user_preferences"
    case consentRecords = "consent_records"
    case healthMeasurements = "health_measurements"
    case symptomEntries = "symptom_entries"
    case painEntries = "pain_entries"
    case userSubstances = "user_substances"
    case substanceRegimens = "substance_regimens"
    case actualAdministrations = "actual_administrations"
    case adverseEffectReports = "adverse_effect_reports"
    case auditEvents = "audit_events"
}

/// Every user-owned record that is stored locally and synchronized.
///
/// Conventions (required so JSON payloads map 1:1 onto Postgres columns):
/// - Property names are camelCase with lower-cased acronyms (`userId`, not `userID`)
///   so `convertToSnakeCase` / `convertFromSnakeCase` round-trip.
/// - `version` is an optimistic-concurrency counter enforced by a server trigger.
/// - `deletedAt` is a soft-delete tombstone so deletions sync like any other change.
public protocol SyncableRecord: Codable, Sendable, Identifiable, Equatable where ID == UUID {
    static var entity: EntityName { get }
    /// Append-only records are never updated after creation (corrections are new records).
    static var isAppendOnly: Bool { get }
    var id: UUID { get }
    var userId: UUID { get }
    /// Client-side modification time (device clock). Used for conflict resolution tie-breaks.
    var clientUpdatedAt: Date { get set }
    var version: Int { get set }
    var deletedAt: Date? { get set }
    /// Date used to order/filter records locally (e.g. measurement time).
    var sortDate: Date { get }
    /// Optional secondary index (e.g. metric kind) for local queries.
    var indexTag: String? { get }
}

public extension SyncableRecord {
    static var isAppendOnly: Bool { false }
    var indexTag: String? { nil }
    var isDeleted: Bool { deletedAt != nil }
}

/// Shared JSON coders. Snake-case keys + ISO-8601 dates with fractional seconds,
/// which PostgREST accepts for `timestamptz` columns.
public enum VitalJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISO8601.format(date))
        }
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISO8601.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date: \(s)")
            }
            return date
        }
        return d
    }
}

public enum ISO8601 {
    public static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: true).timeSeparator(.colon)
            .timeZone(separator: .omitted))
    }

    public static func parse(_ string: String) -> Date? {
        // Postgres returns e.g. "2026-03-08T09:30:00.123456+00:00"; accept several shapes.
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? fractional.parse(string) { return d }
        if let d = try? Date.ISO8601FormatStyle().parse(string) { return d }
        // Trim microseconds to milliseconds which the formatter handles reliably.
        if let dot = string.firstIndex(of: ".") {
            let afterDot = string[string.index(after: dot)...]
            let digits = afterDot.prefix(while: \.isNumber)
            let rest = afterDot.dropFirst(digits.count)
            let trimmed = string[..<dot] + "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0) + rest
            if let d = try? fractional.parse(String(trimmed)) { return d }
        }
        return nil
    }
}

/// Opaque stored form of a record, used by `RecordStore` implementations.
public struct StoredEnvelope: Sendable, Equatable {
    public var entity: EntityName
    public var id: UUID
    public var userId: UUID
    public var payload: Data
    public var sortDate: Date
    public var indexTag: String?
    public var isDeleted: Bool

    public init<R: SyncableRecord>(_ record: R) throws {
        entity = R.entity
        id = record.id
        userId = record.userId
        payload = try VitalJSON.encoder().encode(record)
        sortDate = record.sortDate
        indexTag = record.indexTag
        isDeleted = record.isDeleted
    }

    public init(entity: EntityName, id: UUID, userId: UUID, payload: Data, sortDate: Date, indexTag: String?, isDeleted: Bool) {
        self.entity = entity; self.id = id; self.userId = userId; self.payload = payload
        self.sortDate = sortDate; self.indexTag = indexTag; self.isDeleted = isDeleted
    }

    public func decode<R: SyncableRecord>(_ type: R.Type) throws -> R {
        try VitalJSON.decoder().decode(R.self, from: payload)
    }
}

/// Injectable clock so time-dependent logic is testable.
public protocol TimeSource: Sendable {
    var now: Date { get }
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedTimeSource: TimeSource {
    public var now: Date
    public init(_ now: Date) { self.now = now }
}
