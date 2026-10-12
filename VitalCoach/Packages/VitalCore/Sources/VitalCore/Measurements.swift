import Foundation

/// Body/health metrics tracked in Phase 1.
///
/// Values are always stored in the canonical unit listed in `canonicalUnit`;
/// display conversion happens at the edge.
///
/// Body-composition terms are kept distinct on purpose:
/// - `leanBodyMass` — what HealthKit calls lean body mass; consumer scales (incl. Arboleaf)
///   usually write their *fat-free mass estimate* here. We label the source accordingly.
/// - `fatFreeMass` — total mass minus fat mass, entered manually or from DEXA/BIA reports.
/// - `skeletalMuscleMass` — muscle attached to the skeleton; a *subset* of fat-free mass.
///   HealthKit has no type for it, so it is manual-entry only.
/// - `scaleMuscleMass` — a manufacturer-specific "muscle mass" figure whose definition is
///   proprietary. Never compared with skeletal muscle mass.
public enum MetricKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case fatFreeMass = "fat_free_mass"
    case skeletalMuscleMass = "skeletal_muscle_mass"
    case scaleMuscleMass = "scale_muscle_mass"
    case bodyMassIndex = "body_mass_index"
    case waistCircumference = "waist_circumference"
    case hipCircumference = "hip_circumference"
    case chestCircumference = "chest_circumference"
    case armCircumference = "arm_circumference"
    case thighCircumference = "thigh_circumference"
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariabilitySDNN = "hrv_sdnn"
    case stepCount = "step_count"
    case activeEnergy = "active_energy"
    case height = "height"

    public var id: String { rawValue }

    public enum Canonical: String, Codable, Sendable {
        case kilogram = "kg", percent = "%", centimeter = "cm", beatsPerMinute = "bpm"
        case millisecond = "ms", count = "count", kilocalorie = "kcal", kgPerM2 = "kg/m2"
    }

    public var canonicalUnit: Canonical {
        switch self {
        case .bodyMass, .leanBodyMass, .fatFreeMass, .skeletalMuscleMass, .scaleMuscleMass: .kilogram
        case .bodyFatPercentage: .percent
        case .bodyMassIndex: .kgPerM2
        case .waistCircumference, .hipCircumference, .chestCircumference, .armCircumference,
             .thighCircumference, .height: .centimeter
        case .heartRate, .restingHeartRate: .beatsPerMinute
        case .heartRateVariabilitySDNN: .millisecond
        case .stepCount: .count
        case .activeEnergy: .kilocalorie
        }
    }

    public var displayName: String {
        switch self {
        case .bodyMass: "Weight"
        case .bodyFatPercentage: "Body fat"
        case .leanBodyMass: "Lean body mass"
        case .fatFreeMass: "Fat-free mass"
        case .skeletalMuscleMass: "Skeletal muscle mass"
        case .scaleMuscleMass: "Muscle mass (scale estimate)"
        case .bodyMassIndex: "BMI"
        case .waistCircumference: "Waist"
        case .hipCircumference: "Hips"
        case .chestCircumference: "Chest"
        case .armCircumference: "Upper arm"
        case .thighCircumference: "Thigh"
        case .heartRate: "Heart rate"
        case .restingHeartRate: "Resting heart rate"
        case .heartRateVariabilitySDNN: "HRV (SDNN)"
        case .stepCount: "Steps"
        case .activeEnergy: "Active energy"
        case .height: "Height"
        }
    }

    /// Short explanation shown next to estimates so users understand what the number means.
    public var explanation: String? {
        switch self {
        case .bodyFatPercentage:
            "Consumer smart scales estimate body fat with bioelectrical impedance. Hydration, meals and time of day can shift readings by several percentage points; watch multi-week trends rather than single readings."
        case .leanBodyMass:
            "Usually the scale's estimate of everything that is not fat (muscle, bone, water, organs). It is not the same as muscle mass."
        case .scaleMuscleMass:
            "A manufacturer-specific estimate. Its exact definition is not published, so it cannot be compared with lab measurements of skeletal muscle."
        case .skeletalMuscleMass:
            "Muscle attached to the skeleton, typically from DEXA or a clinical-grade analyzer report."
        case .bodyMassIndex:
            "BMI is weight divided by height squared. It does not distinguish muscle from fat."
        case .heartRateVariabilitySDNN:
            "Apple Watch reports HRV as SDNN. Values vary widely between people; compare against your own baseline."
        default: nil
        }
    }

    /// Daily totals (steps, energy) are summed; everything else is averaged/latest.
    public var isCumulative: Bool { self == .stepCount || self == .activeEnergy }

    /// Plausibility range in canonical units. Entries outside are rejected as likely typos.
    public var plausibleRange: ClosedRange<Double> {
        switch self {
        case .bodyMass: 20...400
        case .bodyFatPercentage: 2...75
        case .leanBodyMass, .fatFreeMass: 10...200
        case .skeletalMuscleMass, .scaleMuscleMass: 5...150
        case .bodyMassIndex: 8...90
        case .waistCircumference, .hipCircumference, .chestCircumference: 30...250
        case .armCircumference, .thighCircumference: 10...120
        case .heartRate: 20...250
        case .restingHeartRate: 20...150
        case .heartRateVariabilitySDNN: 1...300
        case .stepCount: 0...150_000
        case .activeEnergy: 0...15_000
        case .height: 100...250
        }
    }

    public static let bodyComposition: [MetricKind] = [.bodyMass, .bodyFatPercentage, .leanBodyMass, .fatFreeMass, .skeletalMuscleMass, .scaleMuscleMass, .bodyMassIndex]
    public static let circumferences: [MetricKind] = [.waistCircumference, .hipCircumference, .chestCircumference, .armCircumference, .thighCircumference]
    public static let manualEntryKinds: [MetricKind] = [.bodyMass, .bodyFatPercentage, .fatFreeMass, .skeletalMuscleMass, .scaleMuscleMass] + circumferences + [.restingHeartRate, .height]
}

/// Where a measurement came from.
public enum MeasurementSourceKind: String, Codable, Sendable {
    case healthKit = "healthkit"
    case manual
    case derived
}

/// How much to trust a value.
public enum MeasurementQuality: String, Codable, Sendable {
    /// Device-measured (e.g. scale weight, watch heart rate).
    case measured
    /// Algorithmic estimate from a device (e.g. BIA body fat).
    case estimated
    /// User typed it in.
    case selfReported = "self_reported"
    /// Calculated by the app from other values (e.g. BMI from weight + height).
    case derived
}

public struct HealthMeasurement: SyncableRecord {
    public static let entity = EntityName.healthMeasurements

    public var id: UUID
    public var userId: UUID
    public var kind: MetricKind
    /// Value in `kind.canonicalUnit`.
    public var value: Double
    public var unit: MetricKind.Canonical
    public var startAt: Date
    public var endAt: Date
    public var sourceKind: MeasurementSourceKind
    /// Human-readable origin, e.g. "Arboleaf", "Apple Watch", "Manual entry".
    public var sourceName: String?
    /// Bundle identifier of the app that wrote the HealthKit sample, when available.
    public var sourceBundleId: String?
    /// Stable identifier for deduplication (HealthKit sample UUID).
    public var externalId: String?
    public var quality: MeasurementQuality
    public var note: String?
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, kind: MetricKind, value: Double, startAt: Date, endAt: Date? = nil,
                sourceKind: MeasurementSourceKind, sourceName: String? = nil, sourceBundleId: String? = nil,
                externalId: String? = nil, quality: MeasurementQuality, note: String? = nil,
                clientUpdatedAt: Date = Date(), version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.kind = kind; self.value = value; self.unit = kind.canonicalUnit
        self.startAt = startAt; self.endAt = endAt ?? startAt; self.sourceKind = sourceKind
        self.sourceName = sourceName; self.sourceBundleId = sourceBundleId; self.externalId = externalId
        self.quality = quality; self.note = note; self.clientUpdatedAt = clientUpdatedAt
        self.version = version; self.deletedAt = deletedAt
    }

    public var sortDate: Date { startAt }
    public var indexTag: String? { kind.rawValue }
}

public enum MeasurementValidationError: Error, Equatable, Sendable {
    case outOfRange(MetricKind, ClosedRange<Double>)
    case futureDate
    case notANumber
}

public enum MeasurementFactory {
    /// Creates a validated manual measurement. Input value is in the user's display unit.
    public static func manual(userId: UUID, kind: MetricKind, displayValue: Double, units: UnitSystem,
                              at date: Date, now: Date, note: String? = nil) throws -> HealthMeasurement {
        guard displayValue.isFinite else { throw MeasurementValidationError.notANumber }
        guard date <= now.addingTimeInterval(5 * 60) else { throw MeasurementValidationError.futureDate }
        let canonical = MetricDisplay.toCanonical(displayValue, kind: kind, units: units)
        guard kind.plausibleRange.contains(canonical) else {
            throw MeasurementValidationError.outOfRange(kind, kind.plausibleRange)
        }
        return HealthMeasurement(userId: userId, kind: kind, value: canonical, startAt: date, sourceKind: .manual,
                                 sourceName: "Manual entry", quality: .selfReported, note: note, clientUpdatedAt: now)
    }
}

/// Conversion between canonical storage units and user display units.
public enum MetricDisplay {
    public static func toCanonical(_ value: Double, kind: MetricKind, units: UnitSystem) -> Double {
        switch kind.canonicalUnit {
        case .kilogram: units.mass.toKilograms(value)
        case .centimeter: units.length.toCentimeters(value)
        default: value
        }
    }

    public static func fromCanonical(_ value: Double, kind: MetricKind, units: UnitSystem) -> Double {
        switch kind.canonicalUnit {
        case .kilogram: units.mass.fromKilograms(value)
        case .centimeter: units.length.fromCentimeters(value)
        default: value
        }
    }

    public static func unitLabel(_ kind: MetricKind, units: UnitSystem) -> String {
        switch kind.canonicalUnit {
        case .kilogram: units.mass.rawValue
        case .centimeter: units.length.rawValue
        case .percent: "%"
        case .beatsPerMinute: "bpm"
        case .millisecond: "ms"
        case .count: kind == .stepCount ? "steps" : ""
        case .kilocalorie: "kcal"
        case .kgPerM2: ""
        }
    }

    public static func format(_ value: Double, kind: MetricKind, units: UnitSystem) -> String {
        let v = fromCanonical(value, kind: kind, units: units)
        let digits: Int = switch kind {
        case .stepCount, .activeEnergy, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN: 0
        default: 1
        }
        let number = v.formatted(.number.precision(.fractionLength(digits)))
        let label = unitLabel(kind, units: units)
        return label.isEmpty ? number : "\(number) \(label)"
    }
}

public enum BodyMetrics {
    /// BMI = kg / m². Returns nil when inputs are missing or implausible — never guessed.
    public static func bmi(weightKg: Double?, heightCm: Double?) -> Double? {
        guard let w = weightKg, let h = heightCm, w > 0, h >= 100, h <= 250 else { return nil }
        let m = h / 100
        return w / (m * m)
    }

    /// Fat mass and fat-free mass derived from a weight + body-fat% pair taken together.
    public static func fatFreeMass(weightKg: Double, bodyFatPercent: Double) -> Double? {
        guard weightKg > 0, (0..<100).contains(bodyFatPercent) else { return nil }
        return weightKg * (1 - bodyFatPercent / 100)
    }
}
