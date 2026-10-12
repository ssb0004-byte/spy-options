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
    /// Formats with exactly millisecond precision, rounding (not truncating) so that
    /// format → parse → format is stable. Truncation of binary floating-point seconds would
    /// otherwise lose 1 ms per round trip.
    public static func format(_ date: Date) -> String {
        let ms = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = ms >= 0 ? ms / 1000 : (ms - 999) / 1000
        let fraction = ms - seconds * 1000
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03lldZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, fraction)
    }

    public static func parse(_ string: String) -> Date? {
        // Accepts "2026-03-08T09:30:00Z", "…00.123Z", "…00.123456+00:00" (Postgres) and offsets.
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.count > 10, s[s.index(s.startIndex, offsetBy: 10)] == " " {
            s.replaceSubrange(s.index(s.startIndex, offsetBy: 10)...s.index(s.startIndex, offsetBy: 10), with: "T")
        }
        var fraction: Decimal = 0
        if let dot = s.firstIndex(of: ".") {
            let digits = s[s.index(after: dot)...].prefix(while: \.isNumber)
            guard !digits.isEmpty else { return nil }
            fraction = Decimal(string: "0." + digits) ?? 0
            s.removeSubrange(dot..<s.index(dot, offsetBy: digits.count + 1))
        }
        if s.hasSuffix("+00") || s.hasSuffix("-00") { s += ":00" }
        guard let whole = try? Date.ISO8601FormatStyle().parse(s) else { return nil }
        let ms = (NSDecimalNumber(decimal: fraction * 1000).doubleValue).rounded()
        return Date(timeIntervalSince1970: whole.timeIntervalSince1970 + ms / 1000)
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

/// Deterministic UUID (RFC 9562 version 8 layout) from a string, using two FNV-1a 64-bit hashes.
/// Used so the same HealthKit sample imported on two devices maps to the same record id.
/// Not cryptographic — ids are not secrets, and RLS (not id secrecy) protects data.
public enum DeterministicUUID {
    public static func make(_ name: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 {
            var h: UInt64 = 0xcbf29ce484222325 ^ seed
            for b in name.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
            return h
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        let a = fnv(0), b = fnv(0x9E3779B97F4A7C15)
        for i in 0..<8 { bytes[i] = UInt8((a >> (UInt64(i) * 8)) & 0xff); bytes[8 + i] = UInt8((b >> (UInt64(i) * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // version 8
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
