import Foundation

/// A planned administration derived deterministically from a regimen.
///
/// Planned doses are *not* stored: they are recomputed from the (immutable, versioned) regimen.
/// The `occurrenceKey` — regimen id + local date + local time — is independent of time zone,
/// so a dose logged in New York still matches the same planned slot after flying to London.
public struct PlannedDose: Sendable, Equatable, Identifiable, Hashable {
    public var regimenId: UUID
    public var userSubstanceId: UUID
    public var localDate: LocalDate
    public var localTime: LocalTime
    public var scheduledAt: Date
    public var dose: DoseQuantity
    public var route: AdministrationRoute
    /// True when the wall-clock time did not exist (DST spring-forward) and was shifted.
    public var wasShiftedByDST: Bool

    public var occurrenceKey: String { PlannedDose.key(regimenId: regimenId, date: localDate, time: localTime) }
    public var id: String { occurrenceKey }

    public static func key(regimenId: UUID, date: LocalDate, time: LocalTime) -> String {
        "\(regimenId.uuidString.lowercased())|\(date)|\(time)"
    }
}

public enum ScheduleGenerator {
    /// Planned doses for local days `from...to` (inclusive).
    /// - Parameter deviceTimeZone: used when the regimen follows the device zone.
    public static func plannedDoses(for regimen: SubstanceRegimen, from: LocalDate, to: LocalDate,
                                    deviceTimeZone: TimeZone) -> [PlannedDose] {
        let schedule = regimen.schedule
        guard schedule.frequency != .asNeeded, !regimen.isDeleted, from <= to else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = schedule.timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? deviceTimeZone

        var result: [PlannedDose] = []
        let span = from.days(to: to)
        for offset in 0...max(span, 0) {
            guard let day = from.adding(days: offset, calendar: calendar), regimen.isActive(on: day),
                  isScheduledDay(day, regimen: regimen, calendar: calendar),
                  let dayStart = day.startOfDay(in: calendar) else { continue }
            for time in schedule.times {
                guard let at = resolve(time, on: dayStart, calendar: calendar) else { continue }
                let actual = calendar.dateComponents([.hour, .minute], from: at.date)
                result.append(PlannedDose(regimenId: regimen.id, userSubstanceId: regimen.userSubstanceId, localDate: day,
                                          localTime: time, scheduledAt: at.date, dose: regimen.dose, route: regimen.route,
                                          wasShiftedByDST: at.shifted || actual.hour != time.hour || actual.minute != time.minute))
            }
        }
        return result.sorted { $0.scheduledAt < $1.scheduledAt }
    }

    static func isScheduledDay(_ day: LocalDate, regimen: SubstanceRegimen, calendar: Calendar) -> Bool {
        let s = regimen.schedule
        let sinceStart = regimen.startDate.days(to: day)
        guard sinceStart >= 0 else { return false }
        if let on = s.cycleOnDays, let off = s.cycleOffDays, on + off > 0 {
            if sinceStart % (on + off) >= on { return false }
        }
        switch s.frequency {
        case .daily: return true
        case .everyNDays: return sinceStart % max(s.intervalDays ?? 1, 1) == 0
        case .weekdays:
            guard let start = day.startOfDay(in: calendar) else { return false }
            return (s.weekdays ?? []).contains(calendar.component(.weekday, from: start))
        case .asNeeded: return false
        }
    }

    /// Resolves a wall-clock time on a given day using only UTC-offset lookups, so the result is
    /// identical on every platform:
    /// - Non-existent times (spring forward, e.g. 02:30) move forward by the gap (→ 03:30).
    /// - Repeated times (fall back, e.g. 01:30 occurs twice) use the *first* occurrence,
    ///   so a dose is scheduled once, never twice.
    static func resolve(_ time: LocalTime, on dayStart: Date, calendar: Calendar) -> (date: Date, shifted: Bool)? {
        let tz = calendar.timeZone
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let ymd = calendar.dateComponents([.year, .month, .day], from: dayStart)
        // The wall-clock time expressed as if it were UTC.
        guard let wall = utc.date(from: DateComponents(year: ymd.year, month: ymd.month, day: ymd.day,
                                                       hour: time.hour, minute: time.minute)) else { return nil }
        let before = TimeInterval(tz.secondsFromGMT(for: wall.addingTimeInterval(-86_400)))
        let after = TimeInterval(tz.secondsFromGMT(for: wall.addingTimeInterval(86_400)))
        let candidates = [wall.addingTimeInterval(-before), wall.addingTimeInterval(-after)]
            .filter { TimeInterval(tz.secondsFromGMT(for: $0)) == wall.timeIntervalSince($0) }
        if let first = candidates.min() { return (first, false) }
        // Inside a DST gap: interpret with the pre-transition offset, which lands after the gap.
        return (wall.addingTimeInterval(-before), true)
    }
}

// MARK: - Actual administrations

public enum AdministrationAction: String, Codable, Sendable {
    /// The dose was taken (possibly late or at a different amount).
    case taken
    /// The user deliberately did not take it.
    case skipped
    /// The user confirms they forgot/missed it.
    case missed
    /// Cancels the record it supersedes (an "undo"); the slot returns to "not logged".
    case voided
}

/// Append-only record of what actually happened. Corrections create a new record with
/// `supersedesId` pointing at the record being corrected; nothing is overwritten.
public struct ActualAdministration: SyncableRecord {
    public static let entity = EntityName.actualAdministrations
    public static let isAppendOnly = true

    public var id: UUID
    public var userId: UUID
    public var userSubstanceId: UUID
    public var regimenId: UUID?
    /// Links to a planned slot; nil for as-needed or unscheduled doses.
    public var occurrenceKey: String?
    public var scheduledFor: Date?
    public var action: AdministrationAction
    public var takenAt: Date?
    public var doseAmount: Decimal?
    public var doseUnit: DoseUnit?
    public var route: AdministrationRoute?
    /// Injection or application site, free text.
    public var site: String?
    public var note: String?
    public var supersedesId: UUID?
    /// Device time zone when recorded, for interpreting history across travel.
    public var timeZoneIdentifier: String
    public var recordedAt: Date
    public var clientUpdatedAt: Date
    public var version: Int
    public var deletedAt: Date?

    public init(id: UUID = UUID(), userId: UUID, userSubstanceId: UUID, regimenId: UUID? = nil, occurrenceKey: String? = nil,
                scheduledFor: Date? = nil, action: AdministrationAction, takenAt: Date? = nil, dose: DoseQuantity? = nil,
                route: AdministrationRoute? = nil, site: String? = nil, note: String? = nil, supersedesId: UUID? = nil,
                timeZoneIdentifier: String, recordedAt: Date, version: Int = 0, deletedAt: Date? = nil) {
        self.id = id; self.userId = userId; self.userSubstanceId = userSubstanceId; self.regimenId = regimenId
        self.occurrenceKey = occurrenceKey; self.scheduledFor = scheduledFor; self.action = action; self.takenAt = takenAt
        self.doseAmount = dose?.amount; self.doseUnit = dose?.unit; self.route = route; self.site = site; self.note = note
        self.supersedesId = supersedesId; self.timeZoneIdentifier = timeZoneIdentifier; self.recordedAt = recordedAt
        self.clientUpdatedAt = recordedAt; self.version = version; self.deletedAt = deletedAt
    }

    public var dose: DoseQuantity? { doseAmount.flatMap { a in doseUnit.map { DoseQuantity(amount: a, unit: $0) } } }
    public var sortDate: Date { takenAt ?? scheduledFor ?? recordedAt }
    public var indexTag: String? { userSubstanceId.uuidString }
}

public enum DoseStatus: Equatable, Sendable {
    case upcoming
    /// Within the window around the scheduled time; awaiting confirmation.
    case due
    case taken(late: Bool)
    case skipped
    case missed
    /// Past the window with no record. Explicitly *not* assumed taken.
    case notLogged

    public var label: String {
        switch self {
        case .upcoming: "Upcoming"
        case .due: "Due"
        case .taken(let late): late ? "Taken late" : "Taken"
        case .skipped: "Skipped"
        case .missed: "Missed"
        case .notLogged: "Not logged"
        }
    }
}

public enum DoseLog {
    /// How long after the scheduled time a dose still counts as "due" before "not logged".
    public static let dueWindow: TimeInterval = 3 * 3600
    /// Taken more than this after schedule counts as late.
    public static let lateThreshold: TimeInterval = 60 * 60

    /// Records still in effect: not superseded by a later record, not voided, not deleted.
    public static func effectiveRecords(_ records: [ActualAdministration]) -> [ActualAdministration] {
        let live = records.filter { !$0.isDeleted }
        let superseded = Set(live.compactMap(\.supersedesId))
        return live.filter { !superseded.contains($0.id) && $0.action != .voided }
    }

    /// Full correction chain for a record, oldest first (for audit display).
    public static func history(of id: UUID, in records: [ActualAdministration]) -> [ActualAdministration] {
        let byId = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let bySuperseded = Dictionary(records.compactMap { r in r.supersedesId.map { ($0, r) } }, uniquingKeysWith: { a, b in a.recordedAt >= b.recordedAt ? a : b })
        var root = byId[id]
        while let r = root, let prev = r.supersedesId.flatMap({ byId[$0] }) { root = prev }
        var chain: [ActualAdministration] = []
        var cursor = root
        while let c = cursor, !chain.contains(where: { $0.id == c.id }) {
            chain.append(c)
            cursor = bySuperseded[c.id]
        }
        return chain
    }

    public static func status(of planned: PlannedDose, records: [ActualAdministration], now: Date) -> DoseStatus {
        let matching = effectiveRecords(records).filter { $0.occurrenceKey == planned.occurrenceKey }
        if let r = matching.max(by: { $0.recordedAt < $1.recordedAt }) {
            switch r.action {
            case .taken:
                let t = r.takenAt ?? r.recordedAt
                return .taken(late: t.timeIntervalSince(planned.scheduledAt) > lateThreshold)
            case .skipped: return .skipped
            case .missed: return .missed
            case .voided: break
            }
        }
        if now < planned.scheduledAt.addingTimeInterval(-15 * 60) { return .upcoming }
        if now <= planned.scheduledAt.addingTimeInterval(dueWindow) { return .due }
        return .notLogged
    }

    public struct Adherence: Equatable, Sendable {
        public var planned: Int, taken: Int, late: Int, skipped: Int, missed: Int, notLogged: Int
        /// Taken / doses whose outcome is known. Nil when nothing is known yet.
        public var takenRateOfLogged: Double? {
            let logged = taken + skipped + missed
            return logged > 0 ? Double(taken) / Double(logged) : nil
        }
    }

    /// Adherence over past planned doses only (upcoming/due are excluded).
    public static func adherence(planned: [PlannedDose], records: [ActualAdministration], now: Date) -> Adherence {
        var a = Adherence(planned: 0, taken: 0, late: 0, skipped: 0, missed: 0, notLogged: 0)
        for p in planned {
            switch status(of: p, records: records, now: now) {
            case .upcoming, .due: continue
            case .taken(let late): a.taken += 1; if late { a.late += 1 }
            case .skipped: a.skipped += 1
            case .missed: a.missed += 1
            case .notLogged: a.notLogged += 1
            }
            a.planned += 1
        }
        return a
    }
}

/// Combines substances and regimens into the user's routine.
public enum RoutinePlanner {
    /// Planned doses for all *active* substances in the local-date range.
    /// Paused/planned/completed/discontinued/deleted substances produce no planned doses.
    public static func planned(substances: [UserSubstance], regimens: [SubstanceRegimen], from: LocalDate, to: LocalDate,
                               deviceTimeZone: TimeZone) -> [PlannedDose] {
        let active = Set(substances.filter { $0.status == .active && !$0.isDeleted }.map(\.id))
        return regimens
            .filter { active.contains($0.userSubstanceId) && !$0.isDeleted }
            .flatMap { ScheduleGenerator.plannedDoses(for: $0, from: from, to: to, deviceTimeZone: deviceTimeZone) }
            .sorted { $0.scheduledAt < $1.scheduledAt }
    }

    /// The regimen in effect for a substance on a given day (latest start wins).
    public static func currentRegimen(for substanceId: UUID, regimens: [SubstanceRegimen], on day: LocalDate) -> SubstanceRegimen? {
        regimens.filter { $0.userSubstanceId == substanceId && $0.isActive(on: day) }.max { $0.startDate < $1.startDate }
            ?? regimens.filter { $0.userSubstanceId == substanceId && !$0.isDeleted && $0.startDate > day }.min { $0.startDate < $1.startDate }
    }

    /// Regimen history for a substance, newest first.
    public static func history(for substanceId: UUID, regimens: [SubstanceRegimen]) -> [SubstanceRegimen] {
        regimens.filter { $0.userSubstanceId == substanceId && !$0.isDeleted }.sorted { $0.startDate > $1.startDate }
    }

    /// Creates the record for a one-tap / notification log. Never invoked automatically.
    public static func log(_ action: AdministrationAction, planned p: PlannedDose, userId: UUID, at now: Date, timeZone: TimeZone,
                           takenAt: Date? = nil, dose: DoseQuantity? = nil, note: String? = nil, supersedes: UUID? = nil) -> ActualAdministration {
        ActualAdministration(userId: userId, userSubstanceId: p.userSubstanceId, regimenId: p.regimenId, occurrenceKey: p.occurrenceKey,
                             scheduledFor: p.scheduledAt, action: action,
                             takenAt: action == .taken ? (takenAt ?? now) : nil,
                             dose: action == .taken ? (dose ?? p.dose) : nil, route: action == .taken ? p.route : nil,
                             note: note, supersedesId: supersedes, timeZoneIdentifier: timeZone.identifier, recordedAt: now)
    }
}
