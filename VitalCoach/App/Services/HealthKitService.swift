import Foundation
import HealthKit
import VitalCore

/// Reads health data from Apple Health. Read-only: the app never writes to HealthKit in Phase 1.
///
/// Platform facts this design respects:
/// - Read authorization status is private: iOS never tells an app whether reading was allowed.
///   We therefore report "requested — no data yet" until samples actually arrive.
/// - Arboleaf (and other scale apps) write weight / body fat % / BMI / lean body mass into
///   HealthKit; there is no public Arboleaf API, so HealthKit is the only integration.
/// - Samples are imported incrementally with anchored queries (adds *and* deletions).
/// - High-frequency data (heart rate, steps, energy) is imported as daily statistics.
@MainActor
final class HealthKitService {
    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    private var observers: [HKObserverQuery] = []

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // MARK: Types & units

    static func quantityType(for kind: MetricKind) -> HKQuantityType? {
        guard let entry = HealthKitCatalog.entry(for: kind) else { return nil }
        return HKQuantityType(HKQuantityTypeIdentifier(rawValue: entry.healthKitIdentifier))
    }

    /// Converts HealthKit's units to VitalCore canonical units.
    static func canonicalValue(_ q: HKQuantity, kind: MetricKind) -> Double {
        switch kind.canonicalUnit {
        case .kilogram: q.doubleValue(for: .gramUnit(with: .kilo))
        case .percent: q.doubleValue(for: .percent()) * 100   // HealthKit percent is a 0–1 fraction
        case .centimeter: q.doubleValue(for: .meterUnit(with: .centi))
        case .beatsPerMinute: q.doubleValue(for: .count().unitDivided(by: .minute()))
        case .millisecond: q.doubleValue(for: .secondUnit(with: .milli))
        case .count, .kgPerM2: q.doubleValue(for: .count())
        case .kilocalorie: q.doubleValue(for: .kilocalorie())
        }
    }

    static func hkUnit(for kind: MetricKind) -> HKUnit {
        switch kind.canonicalUnit {
        case .kilogram: .gramUnit(with: .kilo)
        case .percent: .percent()
        case .centimeter: .meterUnit(with: .centi)
        case .beatsPerMinute: .count().unitDivided(by: .minute())
        case .millisecond: .secondUnit(with: .milli)
        case .count, .kgPerM2: .count()
        case .kilocalorie: .kilocalorie()
        }
    }

    // MARK: Authorization

    private func requestedKey(_ kind: MetricKind) -> String { "hk.requested.\(kind.rawValue)" }
    private func receivedKey(_ kind: MetricKind, user: UUID) -> String { "hk.received.\(user.uuidString).\(kind.rawValue)" }

    func status(for kind: MetricKind, user: UUID) -> HealthAccessStatus {
        HealthAccessEvaluator.status(available: isAvailable && Self.quantityType(for: kind) != nil,
                                     requested: defaults.bool(forKey: requestedKey(kind)),
                                     hasReceivedData: defaults.bool(forKey: receivedKey(kind, user: user)))
    }

    /// Requests read access for the given categories only (contextual, per-category requests).
    func requestAccess(for kinds: [MetricKind]) async throws {
        guard isAvailable else { return }
        let types = Set(kinds.compactMap(Self.quantityType(for:)).map { $0 as HKObjectType })
        guard !types.isEmpty else { return }
        try await store.requestAuthorization(toShare: [], read: types)
        for k in kinds { defaults.set(true, forKey: requestedKey(k)) }
    }

    var requestedKinds: [MetricKind] {
        HealthKitCatalog.entries.map(\.kind).filter { defaults.bool(forKey: requestedKey($0)) }
    }

    // MARK: Import

    struct ImportSummary { var inserted = 0, updated = 0, deleted = 0, rejected = 0; var errors: [String] = [] }

    /// Imports new/changed/deleted data for every requested category and saves it through the repository.
    func importAll(user: UUID, repository: Repository, historyDays: Int = 730) async -> ImportSummary {
        var summary = ImportSummary()
        guard isAvailable else { return summary }
        let existing = (try? await repository.all(HealthMeasurement.self, includeDeleted: true)) ?? []
        for kind in requestedKinds {
            guard let entry = HealthKitCatalog.entry(for: kind), let type = Self.quantityType(for: kind) else { continue }
            do {
                var incoming: [ImportedSample] = []
                var deleted: Set<String> = []
                switch entry.strategy {
                case .samples:
                    (incoming, deleted) = try await anchoredChanges(type: type, kind: kind, user: user, historyDays: historyDays)
                case .dailySum:
                    incoming = try await dailyStatistics(type: type, kind: kind, options: .cumulativeSum, days: historyDays)
                case .dailyAverage:
                    incoming = try await dailyStatistics(type: type, kind: kind, options: .discreteAverage, days: historyDays)
                }
                let merged = HealthImportMerger.merge(userId: user, incoming: incoming, deletedExternalIds: deleted,
                                                      existing: existing.filter { $0.kind == kind }, now: Date())
                for m in merged.toSave { try await repository.save(m) }
                if !incoming.isEmpty { defaults.set(true, forKey: receivedKey(kind, user: user)) }
                summary.inserted += merged.inserted; summary.updated += merged.updated
                summary.deleted += merged.deleted; summary.rejected += merged.rejected
            } catch {
                // Typically "authorization not determined" or protected data while locked.
                summary.errors.append("\(kind.displayName): \(error.localizedDescription)")
            }
        }
        return summary
    }

    private func anchorKey(_ kind: MetricKind, user: UUID) -> String { "hk.anchor.\(user.uuidString).\(kind.rawValue)" }

    private func anchoredChanges(type: HKQuantityType, kind: MetricKind, user: UUID, historyDays: Int) async throws -> ([ImportedSample], Set<String>) {
        let key = anchorKey(kind, user: user)
        let anchor = defaults.data(forKey: key).flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let start = Calendar.current.date(byAdding: .day, value: -historyDays, to: Date())
        let predicate = HKQuery.predicateForSamples(withStart: anchor == nil ? start : nil, end: nil)
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.quantitySample(type: type, predicate: predicate)], anchor: anchor)
        let result = try await descriptor.result(for: store)
        let samples = result.addedSamples.map { s in
            ImportedSample(externalId: s.uuid.uuidString, kind: kind, value: Self.canonicalValue(s.quantity, kind: kind),
                           startAt: s.startDate, endAt: s.endDate, sourceName: s.sourceRevision.source.name,
                           sourceBundleId: s.sourceRevision.source.bundleIdentifier)
        }
        let deleted = Set(result.deletedObjects.map { $0.uuid.uuidString })
        if let data = try? NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: key) // anchors contain no health values
        }
        return (samples, deleted)
    }

    /// One value per calendar day. HealthKit's statistics engine de-duplicates overlapping
    /// iPhone + Watch samples, which naive summing would double count.
    private func dailyStatistics(type: HKQuantityType, kind: MetricKind, options: HKStatisticsOptions, days: Int) async throws -> [ImportedSample] {
        let cal = Calendar.current
        let end = Date()
        let start = cal.startOfDay(for: cal.date(byAdding: .day, value: -days, to: end) ?? end)
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end)
        let descriptor = HKStatisticsCollectionQueryDescriptor(predicate: .quantitySample(type: type, predicate: predicate),
                                                               options: options, anchorDate: start,
                                                               intervalComponents: DateComponents(day: 1))
        let collection = try await descriptor.result(for: store)
        var out: [ImportedSample] = []
        collection.enumerateStatistics(from: start, to: end) { stats, _ in
            let q = options.contains(.cumulativeSum) ? stats.sumQuantity() : stats.averageQuantity()
            guard let q else { return } // no data that day → no value (never zero-filled)
            let day = LocalDate(stats.startDate, calendar: cal)
            out.append(ImportedSample(externalId: ImportedSample.dailyId(kind: kind, day: day), kind: kind,
                                      value: Self.canonicalValue(q, kind: kind), startAt: stats.startDate, endAt: stats.endDate,
                                      sourceName: "Apple Health (daily)", sourceBundleId: nil))
        }
        return out
    }

    // MARK: Background delivery

    /// Registers observer queries so new samples (e.g. a morning Arboleaf weigh-in) trigger an
    /// import, including in the background where iOS allows it. Delivery timing is controlled by
    /// iOS and is not guaranteed; manual refresh is always available.
    func startObserving(onChange: @escaping @Sendable () async -> Void) {
        guard isAvailable else { return }
        stopObserving()
        for kind in requestedKinds {
            guard let entry = HealthKitCatalog.entry(for: kind), entry.strategy == .samples,
                  let type = Self.quantityType(for: kind) else { continue }
            let query = Self.makeObserver(type: type, onChange: onChange)
            store.execute(query)
            observers.append(query)
            store.enableBackgroundDelivery(for: type, frequency: .immediate) { _, _ in }
        }
    }

    /// Built outside the main actor: HealthKit calls the handler on a background queue.
    nonisolated private static func makeObserver(type: HKQuantityType, onChange: @escaping @Sendable () async -> Void) -> HKObserverQuery {
        HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
            guard error == nil else { completion(); return }
            Task {
                await onChange()
                completion()
            }
        }
    }

    func stopObserving() {
        observers.forEach { store.stop($0) }
        observers.removeAll()
    }

    func resetAnchors(user: UUID) {
        for kind in MetricKind.allCases {
            defaults.removeObject(forKey: anchorKey(kind, user: user))
            defaults.removeObject(forKey: receivedKey(kind, user: user))
        }
    }
}
