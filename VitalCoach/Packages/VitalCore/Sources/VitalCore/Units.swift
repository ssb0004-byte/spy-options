import Foundation

// MARK: - Body measurement units

public enum MassUnit: String, Codable, Sendable, CaseIterable {
    case kilogram = "kg"
    case pound = "lb"

    /// Exact definition: 1 lb = 0.45359237 kg.
    static let kgPerPound = 0.45359237

    public func toKilograms(_ value: Double) -> Double {
        switch self {
        case .kilogram: value
        case .pound: value * Self.kgPerPound
        }
    }

    public func fromKilograms(_ kg: Double) -> Double {
        switch self {
        case .kilogram: kg
        case .pound: kg / Self.kgPerPound
        }
    }
}

public enum LengthUnit: String, Codable, Sendable, CaseIterable {
    case centimeter = "cm"
    case inch = "in"

    /// Exact definition: 1 in = 2.54 cm.
    public func toCentimeters(_ value: Double) -> Double {
        switch self {
        case .centimeter: value
        case .inch: value * 2.54
        }
    }

    public func fromCentimeters(_ cm: Double) -> Double {
        switch self {
        case .centimeter: cm
        case .inch: cm / 2.54
        }
    }
}

public enum UnitSystem: String, Codable, Sendable, CaseIterable {
    case metric, imperial

    public var mass: MassUnit { self == .metric ? .kilogram : .pound }
    public var length: LengthUnit { self == .metric ? .centimeter : .inch }
}

// MARK: - Dose units

/// Units for substance doses. Only mass units (mcg/mg/g) are inter-convertible.
/// Volume, IU and count units are deliberately *not* converted to mass because that
/// requires a concentration / potency that the app must not assume.
public enum DoseUnit: String, Codable, Sendable, CaseIterable {
    case microgram = "mcg"
    case milligram = "mg"
    case gram = "g"
    case milliliter = "mL"
    case internationalUnit = "IU"
    /// Insulin-style or compounded "units" — not the same as IU.
    case unit = "units"
    case capsule, tablet, softgel, drop, spray, puff, patch, scoop, serving

    public enum Dimension: Sendable { case mass, volume, potency, count }

    public var dimension: Dimension {
        switch self {
        case .microgram, .milligram, .gram: .mass
        case .milliliter: .volume
        case .internationalUnit, .unit: .potency
        case .capsule, .tablet, .softgel, .drop, .spray, .puff, .patch, .scoop, .serving: .count
        }
    }

    /// Scale factor to micrograms for mass units.
    var microgramsPerUnit: Decimal? {
        switch self {
        case .microgram: 1
        case .milligram: 1_000
        case .gram: 1_000_000
        default: nil
        }
    }

    public var displayName: String {
        switch self {
        case .microgram: "mcg"
        case .milligram: "mg"
        case .gram: "g"
        case .milliliter: "mL"
        case .internationalUnit: "IU"
        case .unit: "units"
        default: rawValue
        }
    }
}

public enum DoseConversionError: Error, Equatable, Sendable {
    /// e.g. mL → mg needs a concentration (mg/mL) that must be confirmed by the user.
    case requiresConcentration(from: DoseUnit, to: DoseUnit)
    /// e.g. IU ↔ mg differs per substance and formulation; never converted automatically.
    case notConvertible(from: DoseUnit, to: DoseUnit)
}

/// A dose amount. Uses `Decimal` so fractional doses like 0.25 mg are stored exactly.
public struct DoseQuantity: Codable, Sendable, Equatable, Hashable {
    public var amount: Decimal
    public var unit: DoseUnit

    public init(amount: Decimal, unit: DoseUnit) {
        self.amount = amount
        self.unit = unit
    }

    /// Convert between compatible units. Only mass↔mass is performed automatically;
    /// `concentration` (amount of `concentrationUnit` per mL) enables mL→mass when the
    /// user has explicitly recorded a concentration for the specific product.
    public func converted(to target: DoseUnit, concentrationPerML: DoseQuantity? = nil) throws -> DoseQuantity {
        if target == unit { return self }
        if let from = unit.microgramsPerUnit, let to = target.microgramsPerUnit {
            return DoseQuantity(amount: amount * from / to, unit: target)
        }
        if unit == .milliliter, target.dimension == .mass {
            guard let c = concentrationPerML, c.unit.dimension == .mass else {
                throw DoseConversionError.requiresConcentration(from: unit, to: target)
            }
            let massInSourceUnit = DoseQuantity(amount: amount * c.amount, unit: c.unit)
            return try massInSourceUnit.converted(to: target)
        }
        throw DoseConversionError.notConvertible(from: unit, to: target)
    }

    public var formatted: String {
        "\(DoseQuantity.format(amount)) \(unit.displayName)"
    }

    static func format(_ d: Decimal) -> String {
        var value = d
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 4, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    /// Parses user-entered amounts like "0.25", "1,5" or "1/2". Returns nil for invalid
    /// or non-positive values — the UI must never guess a dose.
    public static func parseAmount(_ text: String, locale: Locale = .current) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let parts = trimmed.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let n = Decimal(string: parts[0]), let dd = Decimal(string: parts[1]), dd != 0 else { return nil }
            let v = n / dd
            return v > 0 ? v : nil
        }
        let sep = locale.decimalSeparator ?? "."
        var normalized = trimmed
        if sep != "." { normalized = normalized.replacingOccurrences(of: sep, with: ".") }
        normalized = normalized.replacingOccurrences(of: ",", with: ".")
        guard normalized.allSatisfy({ $0.isNumber || $0 == "." }),
              normalized.filter({ $0 == "." }).count <= 1,
              let v = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")),
              v > 0 else { return nil }
        return v
    }
}
