import Foundation

/// A HealthKit sample translated to platform-neutral form by the iOS HealthKit layer.
public struct ImportedSample: Sendable, Equatable {
    public var externalId: String       // HKSample UUID, or "daily:<kind>:<yyyy-mm-dd>" for daily statistics
    public var kind: MetricKind
    public var value: Double            // canonical units
    public var startAt: Date
    public var endAt: Date
    public var sourceName: String?
    public var sourceBundleId: String?

    public init(externalId: String, kind: MetricKind, value: Double, startAt: Date, endAt: Date,
                sourceName: String?, sourceBundleId: String?) {
        self.externalId = externalId; self.kind = kind; self.value = value; self.startAt = startAt
        self.endAt = endAt; self.sourceName = sourceName; self.sourceBundleId = sourceBundleId
    }

    public static func dailyId(kind: MetricKind, day: LocalDate) -> String { "daily:\(kind.rawValue):\(day)" }
}

/// Which HealthKit types we read and how. Kept here (pure data) so it is unit-testable;
/// the iOS layer maps `healthKitIdentifier` to `HKQuantityTypeIdentifier`.
public enum HealthKitCatalog {
    public enum Strategy: Sendable { case samples, dailySum, dailyAverage }

    public struct Entry: Sendable {
        public var kind: MetricKind
        public var healthKitIdentifier: String
        public var strategy: Strategy
        /// Quality assigned to imported values of this kind.
        public var quality: MeasurementQuality
    }

    public static let entries: [Entry] = [
        Entry(kind: .bodyMass, healthKitIdentifier: "HKQuantityTypeIdentifierBodyMass", strategy: .samples, quality: .measured),
        // Smart-scale body fat and lean mass are bioimpedance *estimates*.
        Entry(kind: .bodyFatPercentage, healthKitIdentifier: "HKQuantityTypeIdentifierBodyFatPercentage", strategy: .samples, quality: .estimated),
        Entry(kind: .leanBodyMass, healthKitIdentifier: "HKQuantityTypeIdentifierLeanBodyMass", strategy: .samples, quality: .estimated),
        Entry(kind: .bodyMassIndex, healthKitIdentifier: "HKQuantityTypeIdentifierBodyMassIndex", strategy: .samples, quality: .derived),
        Entry(kind: .waistCircumference, healthKitIdentifier: "HKQuantityTypeIdentifierWaistCircumference", strategy: .samples, quality: .measured),
        Entry(kind: .height, healthKitIdentifier: "HKQuantityTypeIdentifierHeight", strategy: .samples, quality: .measured),
        Entry(kind: .restingHeartRate, healthKitIdentifier: "HKQuantityTypeIdentifierRestingHeartRate", strategy: .samples, quality: .measured),
        Entry(kind: .heartRateVariabilitySDNN, healthKitIdentifier: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN", strategy: .samples, quality: .measured),
        // High-frequency types are imported as one daily value to bound storage.
        Entry(kind: .heartRate, healthKitIdentifier: "HKQuantityTypeIdentifierHeartRate", strategy: .dailyAverage, quality: .measured),
        Entry(kind: .stepCount, healthKitIdentifier: "HKQuantityTypeIdentifierStepCount", strategy: .dailySum, quality: .measured),
        Entry(kind: .activeEnergy, healthKitIdentifier: "HKQuantityTypeIdentifierActiveEnergyBurned", strategy: .dailySum, quality: .measured),
    ]

    public static func entry(for kind: MetricKind) -> Entry? { entries.first { $0.kind == kind } }
}

/// Merges a batch of HealthKit changes into existing measurements.
/// - Dedupes by `externalId` (stable HealthKit UUID), so re-imports are idempotent.
/// - Applies HealthKit deletions as tombstones.
/// - Never touches manual entries.
public enum HealthImportMerger {
    public struct Result: Sendable, Equatable {
        public var toSave: [HealthMeasurement]
        public var inserted: Int
        public var updated: Int
        public var deleted: Int
        public var rejected: Int
    }

    public static func merge(userId: UUID, incoming: [ImportedSample], deletedExternalIds: Set<String>,
                             existing: [HealthMeasurement], now: Date) -> Result {
        var byExternal: [String: HealthMeasurement] = [:]
        for m in existing where m.sourceKind == .healthKit {
            if let e = m.externalId { byExternal[e] = m }
        }
        var out: [HealthMeasurement] = []
        var inserted = 0, updated = 0, deleted = 0, rejected = 0

        for s in incoming {
            guard s.value.isFinite, s.kind.plausibleRange.contains(s.value) else { rejected += 1; continue }
            let quality = HealthKitCatalog.entry(for: s.kind)?.quality ?? .measured
            if var m = byExternal[s.externalId] {
                let changed = m.value != s.value || m.startAt != s.startAt || m.endAt != s.endAt || m.isDeleted
                guard changed else { continue }
                m.value = s.value; m.startAt = s.startAt; m.endAt = s.endAt; m.deletedAt = nil
                m.sourceName = s.sourceName; m.sourceBundleId = s.sourceBundleId; m.clientUpdatedAt = now
                byExternal[s.externalId] = m
                out.append(m); updated += 1
            } else {
                let m = HealthMeasurement(userId: userId, kind: s.kind, value: s.value, startAt: s.startAt, endAt: s.endAt,
                                          sourceKind: .healthKit, sourceName: s.sourceName, sourceBundleId: s.sourceBundleId,
                                          externalId: s.externalId, quality: quality, clientUpdatedAt: now)
                byExternal[s.externalId] = m
                out.append(m); inserted += 1
            }
        }
        for ext in deletedExternalIds {
            guard var m = byExternal[ext], !m.isDeleted else { continue }
            m.deletedAt = now; m.clientUpdatedAt = now
            out.append(m); deleted += 1
        }
        return Result(toSave: out, inserted: inserted, updated: updated, deleted: deleted, rejected: rejected)
    }
}

/// HealthKit authorization reality: for *read* access iOS never reveals whether the user
/// granted it ("denied" looks the same as "no data"). The app therefore reports
/// "requested — no data received yet" instead of claiming access was granted.
public enum HealthAccessStatus: String, Sendable, Codable {
    case unavailable          // HealthKit not supported on this device
    case notRequested
    case requestedNoDataYet   // asked; cannot tell whether allowed
    case receivingData        // at least one sample of this type has been read
}

public enum HealthAccessEvaluator {
    public static func status(available: Bool, requested: Bool, hasReceivedData: Bool) -> HealthAccessStatus {
        guard available else { return .unavailable }
        if hasReceivedData { return .receivingData }
        return requested ? .requestedNoDataYet : .notRequested
    }
}

// MARK: - Export

/// Portable JSON export of every local record for the signed-in user.
public enum DataExporter {
    public static let formatVersion = 1

    public static func export(userId: UUID, store: any RecordStore, exportedAt: Date) async throws -> Data {
        var tables: [String: [StoredEnvelope]] = [:]
        for entity in EntityName.allCases {
            tables[entity.rawValue] = try await store.all(entity, userId: userId)
        }
        // Assemble JSON by splicing already-encoded record payloads (keeps Decimal precision).
        var json = Data(#"{"format":"vitalcoach-export","format_version":\#(formatVersion),"#.utf8)
        json += Data(#""exported_at":"\#(ISO8601.format(exportedAt))","user_id":"\#(userId.uuidString.lowercased())","tables":{"#.utf8)
        let names = tables.keys.sorted()
        for (i, name) in names.enumerated() {
            json += Data("\"\(name)\":[".utf8)
            for (j, env) in tables[name]!.enumerated() {
                json += env.payload
                if j < tables[name]!.count - 1 { json += Data(",".utf8) }
            }
            json += Data("]".utf8)
            if i < names.count - 1 { json += Data(",".utf8) }
        }
        json += Data("}}".utf8)
        return json
    }
}
