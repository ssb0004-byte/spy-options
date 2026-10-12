import Foundation

public enum SubstanceCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case prescription
    case overTheCounter = "otc"
    case vitaminMineral = "vitamin_mineral"
    case sportsSupplement = "sports_supplement"
    case peptide
    case hormone
    case compounded
    case other

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .prescription: "Prescription medication"
        case .overTheCounter: "Over-the-counter medication"
        case .vitaminMineral: "Vitamin or mineral"
        case .sportsSupplement: "Sports supplement"
        case .peptide: "Peptide"
        case .hormone: "Hormone"
        case .compounded: "Compounded preparation"
        case .other: "Other"
        }
    }

    /// Changes to these require clinician involvement; the app shows a reminder on edits.
    public var changesRequireClinician: Bool {
        switch self {
        case .prescription, .hormone, .peptide, .compounded: true
        default: false
        }
    }
}

public enum AdministrationRoute: String, Codable, Sendable, CaseIterable, Identifiable {
    case oral, sublingual, buccal, topical, transdermal, subcutaneous, intramuscular
    case intranasal, inhaled, ophthalmic, rectal, vaginal, intravenous, other
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
}

public enum SubstanceStatus: String, Codable, Sendable, CaseIterable {
    case planned, active, paused, completed, discontinued
    public var displayName: String { rawValue.capitalized }
    public var isCurrent: Bool { self == .active }
}

/// Calendar date without time or time zone ("2026-03-08"). Stored as Postgres `date`.
public struct LocalDate: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int

    public init(year: Int, month: Int, day: Int) { self.year = year; self.month = month; self.day = day }

    public init(_ date: Date, calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init?(string: String) {
        let p = string.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3, (1...12).contains(p[1]), (1...31).contains(p[2]) else { return nil }
        self.init(year: p[0], month: p[1], day: p[2])
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public func startOfDay(in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    public func adding(days: Int, calendar: Calendar) -> LocalDate? {
        guard let s = startOfDay(in: utcCalendar), let d = utcCalendar.date(byAdding: .day, value: days, to: s) else { return nil }
        return LocalDate(d, calendar: utcCalendar)
    }

    /// Whole days from `self` to `other` (calendar arithmetic, immune to DST).
    public func days(to other: LocalDate) -> Int {
        guard let a = startOfDay(in: utcCalendar), let b = other.startOfDay(in: utcCalendar) else { return 0 }
        return utcCalendar.dateComponents([.day], from: a, to: b).day ?? 0
    }

    public static func < (l: LocalDate, r: LocalDate) -> Bool {
        (l.year, l.month, l.day) < (r.year, r.month, r.day)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = LocalDate(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid date \(s)")
        }
        self = v
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

private let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// Wall-clock time of day.
public struct LocalTime: Codable, Sendable, Hashable, Comparable, CustomStringConvertible {
    public var hour: Int, minute: Int
    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23); self.minute = min(max(minute, 0), 59)
    }
    public var description: String { String(format: "%02d:%02d", hour, minute) }
    public static func < (l: LocalTime, r: LocalTime) -> Bool { (l.hour, l.minute) < (r.hour, r.minute) }
}

/// A substance the user takes or plans to take. Dose and schedule live in `SubstanceRegimen`
/// so that changes over time are preserved instead of overwritten.
public struct UserSubstance: SyncableRecord {
    public static let entity = EntityName.userSubstances

    public var id: UUID
    public var userId: UUID
    public var name: String
    public var aliases: [String]
    public var category: SubstanceCategory
    /// Free-text formulation exactly as the user/label describes it (e.g. "200 mg/mL in oil").
    public var formulation: String?
    public var indication: String?
    public var status: SubstanceStatus
    public var isPrescribed: Bool
    public var notes: String?
    public var createdAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, name: String, aliases: [String] = [], category: SubstanceCategory,
                formulation: String? = nil, indication: String? = nil, status: SubstanceStatus = .active,
                isPrescribed: Bool = false, notes: String? = nil, createdAt: Date = Date(),
                clientUpdatedAt: Date = Date(), version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.name = name; self.aliases = aliases; self.category = category
        self.formulation = formulation; self.indication = indication; self.status = status
        self.isPrescribed = isPrescribed; self.notes = notes; self.createdAt = createdAt
        self.clientUpdatedAt = clientUpdatedAt; self.version = version; self.deletedAt = deletedAt
    }

    public var sortDate: Date { createdAt }
    public var indexTag: String? { status.rawValue }
}

public enum FrequencyType: String, Codable, Sendable, CaseIterable {
    case daily
    case everyNDays = "every_n_days"
    case weekdays
    case asNeeded = "as_needed"
}

public struct RegimenSchedule: Codable, Sendable, Equatable {
    public var frequency: FrequencyType
    /// For `.everyNDays`.
    public var intervalDays: Int?
    /// For `.weekdays`: 1 = Sunday … 7 = Saturday (Calendar convention).
    public var weekdays: [Int]?
    public var times: [LocalTime]
    /// Optional on/off cycle counted from the regimen start date, e.g. 5 on / 2 off.
    public var cycleOnDays: Int?
    public var cycleOffDays: Int?
    /// nil → follow the device time zone (08:00 stays 08:00 when travelling).
    /// Set → anchored to that zone (useful when exact intervals matter).
    public var timeZoneIdentifier: String?

    public init(frequency: FrequencyType, intervalDays: Int? = nil, weekdays: [Int]? = nil, times: [LocalTime],
                cycleOnDays: Int? = nil, cycleOffDays: Int? = nil, timeZoneIdentifier: String? = nil) {
        self.frequency = frequency; self.intervalDays = intervalDays; self.weekdays = weekdays
        self.times = times.sorted(); self.cycleOnDays = cycleOnDays; self.cycleOffDays = cycleOffDays
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case noTimes, invalidInterval, noWeekdays, invalidCycle, unknownTimeZone
    }

    public func validate() throws {
        if frequency != .asNeeded && times.isEmpty { throw ValidationError.noTimes }
        if frequency == .everyNDays, (intervalDays ?? 0) < 1 { throw ValidationError.invalidInterval }
        if frequency == .weekdays, (weekdays ?? []).filter({ (1...7).contains($0) }).isEmpty { throw ValidationError.noWeekdays }
        if (cycleOnDays == nil) != (cycleOffDays == nil) { throw ValidationError.invalidCycle }
        if let on = cycleOnDays, let off = cycleOffDays, on < 1 || off < 0 { throw ValidationError.invalidCycle }
        if let tz = timeZoneIdentifier, TimeZone(identifier: tz) == nil { throw ValidationError.unknownTimeZone }
    }
}

/// One version of a dose+schedule for a substance. Never edited after doses have been logged
/// against it; a change creates a new regimen that `supersedesId` the previous one.
public struct SubstanceRegimen: SyncableRecord {
    public static let entity = EntityName.substanceRegimens

    public var id: UUID
    public var userId: UUID
    public var userSubstanceId: UUID
    public var doseAmount: Decimal
    public var doseUnit: DoseUnit
    public var route: AdministrationRoute
    public var schedule: RegimenSchedule
    public var startDate: LocalDate
    /// Inclusive last day; nil = ongoing.
    public var endDate: LocalDate?
    public var supersedesId: UUID?
    public var changeReason: String?
    /// Optional user-confirmed concentration (amount per mL) for liquid products.
    public var concentrationAmount: Decimal?
    public var concentrationUnit: DoseUnit?
    public var remindersEnabled: Bool
    public var createdAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, userSubstanceId: UUID, dose: DoseQuantity, route: AdministrationRoute,
                schedule: RegimenSchedule, startDate: LocalDate, endDate: LocalDate? = nil, supersedesId: UUID? = nil,
                changeReason: String? = nil, concentration: DoseQuantity? = nil, remindersEnabled: Bool = true,
                createdAt: Date = Date(), clientUpdatedAt: Date = Date(), version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.userSubstanceId = userSubstanceId
        self.doseAmount = dose.amount; self.doseUnit = dose.unit; self.route = route; self.schedule = schedule
        self.startDate = startDate; self.endDate = endDate; self.supersedesId = supersedesId
        self.changeReason = changeReason; self.concentrationAmount = concentration?.amount
        self.concentrationUnit = concentration?.unit; self.remindersEnabled = remindersEnabled
        self.createdAt = createdAt; self.clientUpdatedAt = clientUpdatedAt; self.version = version; self.deletedAt = deletedAt
    }

    public var dose: DoseQuantity { DoseQuantity(amount: doseAmount, unit: doseUnit) }
    public var sortDate: Date { createdAt }
    public var indexTag: String? { userSubstanceId.uuidString }

    public func isActive(on day: LocalDate) -> Bool {
        guard !isDeleted, day >= startDate else { return false }
        if let end = endDate, day > end { return false }
        return true
    }
}

public enum RegimenHistory {
    /// Ends `current` the day before `newStart` and returns the successor regimen.
    /// History is preserved: the old regimen keeps its doses and schedule.
    public static func revise(_ current: SubstanceRegimen, newDose: DoseQuantity, newRoute: AdministrationRoute,
                              newSchedule: RegimenSchedule, newStart: LocalDate, reason: String?, now: Date,
                              calendar: Calendar) -> (ended: SubstanceRegimen, successor: SubstanceRegimen) {
        var ended = current
        let dayBefore = newStart.adding(days: -1, calendar: calendar) ?? newStart
        // If the change starts on/before the old start, the old regimen never applied going forward.
        ended.endDate = dayBefore < current.startDate ? current.startDate : dayBefore
        ended.clientUpdatedAt = now
        let successor = SubstanceRegimen(userId: current.userId, userSubstanceId: current.userSubstanceId, dose: newDose,
                                         route: newRoute, schedule: newSchedule, startDate: newStart,
                                         supersedesId: current.id, changeReason: reason,
                                         concentration: current.concentrationAmount.flatMap { a in current.concentrationUnit.map { DoseQuantity(amount: a, unit: $0) } },
                                         remindersEnabled: current.remindersEnabled, createdAt: now, clientUpdatedAt: now)
        return (ended, successor)
    }
}

public struct AdverseEffectReport: SyncableRecord {
    public enum Severity: String, Codable, Sendable, CaseIterable { case mild, moderate, severe }
    public static let entity = EntityName.adverseEffectReports

    public var id: UUID
    public var userId: UUID
    public var userSubstanceId: UUID?
    public var summary: String
    public var severity: Severity
    public var onsetAt: Date
    public var resolvedAt: Date?
    public var note: String?
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, userSubstanceId: UUID?, summary: String, severity: Severity,
                onsetAt: Date, resolvedAt: Date? = nil, note: String? = nil, clientUpdatedAt: Date = Date(),
                version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.userSubstanceId = userSubstanceId; self.summary = summary
        self.severity = severity; self.onsetAt = onsetAt; self.resolvedAt = resolvedAt; self.note = note
        self.clientUpdatedAt = clientUpdatedAt; self.version = version; self.deletedAt = deletedAt
    }

    public var sortDate: Date { onsetAt }
    public var indexTag: String? { userSubstanceId?.uuidString }
}
