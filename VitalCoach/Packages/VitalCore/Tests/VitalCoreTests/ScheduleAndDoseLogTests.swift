import Foundation
import Testing
@testable import VitalCore

let newYork = TimeZone(identifier: "America/New_York")!
let london = TimeZone(identifier: "Europe/London")!

func calendar(_ tz: TimeZone) -> Calendar {
    var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c
}

func regimen(user: UUID = UUID(), schedule: RegimenSchedule, start: LocalDate, end: LocalDate? = nil,
             dose: DoseQuantity = DoseQuantity(amount: 5, unit: .milligram)) -> SubstanceRegimen {
    SubstanceRegimen(userId: user, userSubstanceId: UUID(), dose: dose, route: .oral, schedule: schedule, startDate: start, endDate: end)
}

@Suite("Schedule generation")
struct ScheduleTests {
    @Test func dailyTwiceADay() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 20, minute: 0), LocalTime(hour: 8, minute: 0)]),
                        start: LocalDate(year: 2026, month: 5, day: 1))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 1), to: LocalDate(year: 2026, month: 5, day: 3), deviceTimeZone: newYork)
        #expect(p.count == 6)
        #expect(p.first?.localTime == LocalTime(hour: 8, minute: 0))
        #expect(Set(p.map(\.occurrenceKey)).count == 6)
    }

    @Test func springForwardNonexistentTimeShiftsOnceAndIsFlagged() {
        // 2026-03-08 02:30 does not exist in New York (clocks jump 02:00 → 03:00).
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 2, minute: 30)]),
                        start: LocalDate(year: 2026, month: 3, day: 7))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 3, day: 7), to: LocalDate(year: 2026, month: 3, day: 9), deviceTimeZone: newYork)
        #expect(p.count == 3)
        let dst = p[1]
        #expect(dst.localDate == LocalDate(year: 2026, month: 3, day: 8))
        #expect(dst.wasShiftedByDST)
        let comps = calendar(newYork).dateComponents([.hour, .minute], from: dst.scheduledAt)
        #expect(comps.hour == 3 && comps.minute == 30)
        #expect(!p[0].wasShiftedByDST && !p[2].wasShiftedByDST)
    }

    @Test func fallBackRepeatedTimeIsScheduledOnlyOnce() {
        // 2026-11-01 01:30 occurs twice in New York; we must schedule exactly one dose (the first).
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 1, minute: 30)]),
                        start: LocalDate(year: 2026, month: 10, day: 31))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 11, day: 1), to: LocalDate(year: 2026, month: 11, day: 1), deviceTimeZone: newYork)
        #expect(p.count == 1)
        // First 01:30 is EDT (UTC-4) → 05:30 UTC.
        #expect(calendar(TimeZone(identifier: "UTC")!).component(.hour, from: p[0].scheduledAt) == 5)
    }

    @Test func dayLengthChangeKeepsWallClockTime() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 3, day: 7))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 3, day: 7), to: LocalDate(year: 2026, month: 3, day: 9), deviceTimeZone: newYork)
        for dose in p { #expect(calendar(newYork).component(.hour, from: dose.scheduledAt) == 8) }
        #expect(p[1].scheduledAt.timeIntervalSince(p[0].scheduledAt) == 23 * 3600) // short day
    }

    @Test func travelKeepsOccurrenceKeysStable() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 5, day: 1))
        let d = LocalDate(year: 2026, month: 5, day: 10)
        let ny = ScheduleGenerator.plannedDoses(for: r, from: d, to: d, deviceTimeZone: newYork)
        let ldn = ScheduleGenerator.plannedDoses(for: r, from: d, to: d, deviceTimeZone: london)
        #expect(ny[0].occurrenceKey == ldn[0].occurrenceKey)
        #expect(ny[0].scheduledAt.timeIntervalSince(ldn[0].scheduledAt) == 5 * 3600)
    }

    @Test func fixedTimeZonePolicyIgnoresDeviceZone() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)], timeZoneIdentifier: "America/New_York"),
                        start: LocalDate(year: 2026, month: 5, day: 1))
        let d = LocalDate(year: 2026, month: 5, day: 10)
        let a = ScheduleGenerator.plannedDoses(for: r, from: d, to: d, deviceTimeZone: london)
        let b = ScheduleGenerator.plannedDoses(for: r, from: d, to: d, deviceTimeZone: newYork)
        #expect(a[0].scheduledAt == b[0].scheduledAt)
    }

    @Test func everyThirdDayFromStart() {
        let r = regimen(schedule: RegimenSchedule(frequency: .everyNDays, intervalDays: 3, times: [LocalTime(hour: 9, minute: 0)]), start: LocalDate(year: 2026, month: 2, day: 27))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 2, day: 27), to: LocalDate(year: 2026, month: 3, day: 8), deviceTimeZone: newYork)
        #expect(p.map(\.localDate.description) == ["2026-02-27", "2026-03-02", "2026-03-05", "2026-03-08"])
    }

    @Test func weekdaysOnly() {
        // Mon/Wed/Fri = 2,4,6. 2026-05-04 is a Monday.
        let r = regimen(schedule: RegimenSchedule(frequency: .weekdays, weekdays: [2, 4, 6], times: [LocalTime(hour: 7, minute: 0)]), start: LocalDate(year: 2026, month: 5, day: 1))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 4), to: LocalDate(year: 2026, month: 5, day: 10), deviceTimeZone: newYork)
        #expect(p.map(\.localDate.day) == [4, 6, 8])
    }

    @Test func cycleFiveOnTwoOff() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)], cycleOnDays: 5, cycleOffDays: 2), start: LocalDate(year: 2026, month: 6, day: 1))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 6, day: 1), to: LocalDate(year: 2026, month: 6, day: 14), deviceTimeZone: newYork)
        #expect(p.map(\.localDate.day) == [1, 2, 3, 4, 5, 8, 9, 10, 11, 12])
    }

    @Test func respectsStartAndEndDatesAndAsNeeded() {
        let r = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]),
                        start: LocalDate(year: 2026, month: 6, day: 3), end: LocalDate(year: 2026, month: 6, day: 5))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 6, day: 1), to: LocalDate(year: 2026, month: 6, day: 10), deviceTimeZone: newYork)
        #expect(p.map(\.localDate.day) == [3, 4, 5])
        let prn = regimen(schedule: RegimenSchedule(frequency: .asNeeded, times: []), start: LocalDate(year: 2026, month: 6, day: 1))
        #expect(ScheduleGenerator.plannedDoses(for: prn, from: LocalDate(year: 2026, month: 6, day: 1), to: LocalDate(year: 2026, month: 6, day: 10), deviceTimeZone: newYork).isEmpty)
    }

    @Test func scheduleValidation() {
        #expect(throws: RegimenSchedule.ValidationError.noTimes) { try RegimenSchedule(frequency: .daily, times: []).validate() }
        #expect(throws: RegimenSchedule.ValidationError.invalidInterval) { try RegimenSchedule(frequency: .everyNDays, intervalDays: 0, times: [LocalTime(hour: 1, minute: 0)]).validate() }
        #expect(throws: RegimenSchedule.ValidationError.noWeekdays) { try RegimenSchedule(frequency: .weekdays, weekdays: [], times: [LocalTime(hour: 1, minute: 0)]).validate() }
        #expect(throws: RegimenSchedule.ValidationError.invalidCycle) { try RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 1, minute: 0)], cycleOnDays: 5).validate() }
        #expect(throws: RegimenSchedule.ValidationError.unknownTimeZone) { try RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 1, minute: 0)], timeZoneIdentifier: "Mars/Olympus").validate() }
        #expect(throws: Never.self) { try RegimenSchedule(frequency: .asNeeded, times: []).validate() }
    }

    @Test func revisionPreservesHistory() {
        let cal = calendar(newYork)
        let old = regimen(schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 1, day: 1))
        let (ended, next) = RegimenHistory.revise(old, newDose: DoseQuantity(amount: 10, unit: .milligram), newRoute: .oral,
                                                 newSchedule: old.schedule, newStart: LocalDate(year: 2026, month: 2, day: 1),
                                                 reason: "Clinician adjusted", now: Date(), calendar: cal)
        #expect(ended.endDate == LocalDate(year: 2026, month: 1, day: 31))
        #expect(ended.doseAmount == 5)
        #expect(next.supersedesId == old.id)
        #expect(next.startDate == LocalDate(year: 2026, month: 2, day: 1))
        let jan31 = ScheduleGenerator.plannedDoses(for: ended, from: LocalDate(year: 2026, month: 1, day: 31), to: LocalDate(year: 2026, month: 2, day: 1), deviceTimeZone: newYork)
        #expect(jan31.count == 1 && jan31[0].dose.amount == 5)
    }

    @Test func localDateArithmetic() {
        #expect(LocalDate(year: 2026, month: 2, day: 28).adding(days: 1, calendar: calendar(newYork)) == LocalDate(year: 2026, month: 3, day: 1))
        #expect(LocalDate(year: 2028, month: 2, day: 28).adding(days: 1, calendar: calendar(newYork)) == LocalDate(year: 2028, month: 2, day: 29))
        #expect(LocalDate(year: 2026, month: 3, day: 1).days(to: LocalDate(year: 2026, month: 3, day: 15)) == 14)
        #expect(LocalDate(string: "2026-13-01") == nil)
    }
}

@Suite("Dose log")
struct DoseLogTests {
    let user = UUID()
    var planned: PlannedDose {
        let r = regimen(user: user, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 5, day: 1))
        return ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 2), to: LocalDate(year: 2026, month: 5, day: 2), deviceTimeZone: newYork)[0]
    }

    func record(_ action: AdministrationAction, for p: PlannedDose, at: Date, takenAt: Date? = nil, supersedes: UUID? = nil, dose: DoseQuantity? = nil) -> ActualAdministration {
        ActualAdministration(userId: user, userSubstanceId: p.userSubstanceId, regimenId: p.regimenId, occurrenceKey: p.occurrenceKey,
                             scheduledFor: p.scheduledAt, action: action, takenAt: takenAt, dose: dose ?? (action == .taken ? p.dose : nil),
                             supersedesId: supersedes, timeZoneIdentifier: "America/New_York", recordedAt: at)
    }

    @Test func noRecordIsNeverPresumedTaken() {
        let p = planned
        #expect(DoseLog.status(of: p, records: [], now: p.scheduledAt.addingTimeInterval(-3600)) == .upcoming)
        #expect(DoseLog.status(of: p, records: [], now: p.scheduledAt.addingTimeInterval(600)) == .due)
        #expect(DoseLog.status(of: p, records: [], now: p.scheduledAt.addingTimeInterval(86_400)) == .notLogged)
    }

    @Test func takenOnTimeLateSkippedMissed() {
        let p = planned
        let later = p.scheduledAt.addingTimeInterval(86_400)
        #expect(DoseLog.status(of: p, records: [record(.taken, for: p, at: p.scheduledAt, takenAt: p.scheduledAt.addingTimeInterval(300))], now: later) == .taken(late: false))
        #expect(DoseLog.status(of: p, records: [record(.taken, for: p, at: later, takenAt: p.scheduledAt.addingTimeInterval(4 * 3600))], now: later) == .taken(late: true))
        #expect(DoseLog.status(of: p, records: [record(.skipped, for: p, at: later)], now: later) == .skipped)
        #expect(DoseLog.status(of: p, records: [record(.missed, for: p, at: later)], now: later) == .missed)
    }

    @Test func correctionSupersedesWithoutOverwriting() {
        let p = planned
        let original = record(.taken, for: p, at: p.scheduledAt, takenAt: p.scheduledAt)
        // User realises they actually skipped it.
        let fix = record(.skipped, for: p, at: p.scheduledAt.addingTimeInterval(3600), supersedes: original.id)
        let all = [original, fix]
        #expect(DoseLog.effectiveRecords(all).map(\.id) == [fix.id])
        #expect(DoseLog.status(of: p, records: all, now: p.scheduledAt.addingTimeInterval(7200)) == .skipped)
        #expect(DoseLog.history(of: fix.id, in: all).map(\.id) == [original.id, fix.id])
        #expect(DoseLog.history(of: original.id, in: all).map(\.id) == [original.id, fix.id])
    }

    @Test func correctedAmountIsKept() {
        let p = planned
        let original = record(.taken, for: p, at: p.scheduledAt, takenAt: p.scheduledAt)
        let fix = record(.taken, for: p, at: p.scheduledAt.addingTimeInterval(60), takenAt: p.scheduledAt, supersedes: original.id,
                         dose: DoseQuantity(amount: Decimal(string: "2.5")!, unit: .milligram))
        let eff = DoseLog.effectiveRecords([original, fix])
        #expect(eff.count == 1 && eff[0].dose?.amount == Decimal(string: "2.5")!)
    }

    @Test func voidUndoesLog() {
        let p = planned
        let original = record(.taken, for: p, at: p.scheduledAt, takenAt: p.scheduledAt)
        let void = record(.voided, for: p, at: p.scheduledAt.addingTimeInterval(60), supersedes: original.id)
        #expect(DoseLog.status(of: p, records: [original, void], now: p.scheduledAt.addingTimeInterval(86_400)) == .notLogged)
    }

    @Test func adherenceSeparatesNotLoggedFromMissed() {
        let r = regimen(user: user, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 5, day: 1))
        let plan = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 1), to: LocalDate(year: 2026, month: 5, day: 5), deviceTimeZone: newYork)
        let now = plan[4].scheduledAt.addingTimeInterval(60) // last one is "due"
        let recs = [record(.taken, for: plan[0], at: plan[0].scheduledAt, takenAt: plan[0].scheduledAt),
                    record(.taken, for: plan[1], at: plan[1].scheduledAt, takenAt: plan[1].scheduledAt.addingTimeInterval(7200)),
                    record(.skipped, for: plan[2], at: plan[2].scheduledAt)]
        let a = DoseLog.adherence(planned: plan, records: recs, now: now)
        #expect(a == DoseLog.Adherence(planned: 4, taken: 2, late: 1, skipped: 1, missed: 0, notLogged: 1))
        #expect(a.takenRateOfLogged == 2.0 / 3.0)
        #expect(DoseLog.adherence(planned: [], records: [], now: now).takenRateOfLogged == nil)
    }
}

@Suite("Routine planner")
struct RoutinePlannerTests {
    let user = UUID()

    @Test func onlyActiveSubstancesProducePlannedDoses() {
        let active = UserSubstance(userId: user, name: "A", category: .vitaminMineral, status: .active)
        let paused = UserSubstance(userId: user, name: "B", category: .prescription, status: .paused)
        let sched = RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)])
        let day = LocalDate(year: 2026, month: 5, day: 2)
        let rA = SubstanceRegimen(userId: user, userSubstanceId: active.id, dose: DoseQuantity(amount: 1, unit: .capsule), route: .oral, schedule: sched, startDate: day)
        let rB = SubstanceRegimen(userId: user, userSubstanceId: paused.id, dose: DoseQuantity(amount: 1, unit: .tablet), route: .oral, schedule: sched, startDate: day)
        let p = RoutinePlanner.planned(substances: [active, paused], regimens: [rA, rB], from: day, to: day, deviceTimeZone: newYork)
        #expect(p.map(\.userSubstanceId) == [active.id])
    }

    @Test func currentRegimenFollowsRevisions() {
        let s = UUID()
        let sched = RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)])
        let old = SubstanceRegimen(userId: user, userSubstanceId: s, dose: DoseQuantity(amount: 5, unit: .milligram), route: .oral, schedule: sched,
                                   startDate: LocalDate(year: 2026, month: 1, day: 1), endDate: LocalDate(year: 2026, month: 1, day: 31))
        let new = SubstanceRegimen(userId: user, userSubstanceId: s, dose: DoseQuantity(amount: 10, unit: .milligram), route: .oral, schedule: sched,
                                   startDate: LocalDate(year: 2026, month: 2, day: 1))
        #expect(RoutinePlanner.currentRegimen(for: s, regimens: [old, new], on: LocalDate(year: 2026, month: 1, day: 15))?.id == old.id)
        #expect(RoutinePlanner.currentRegimen(for: s, regimens: [old, new], on: LocalDate(year: 2026, month: 3, day: 1))?.id == new.id)
        #expect(RoutinePlanner.currentRegimen(for: s, regimens: [new], on: LocalDate(year: 2025, month: 12, day: 1))?.id == new.id) // planned future
        #expect(RoutinePlanner.history(for: s, regimens: [old, new]).map(\.id) == [new.id, old.id])
    }

    @Test func loggingSkipCarriesNoDose() {
        let r = regimen(user: user, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]), start: LocalDate(year: 2026, month: 5, day: 1))
        let p = ScheduleGenerator.plannedDoses(for: r, from: LocalDate(year: 2026, month: 5, day: 1), to: LocalDate(year: 2026, month: 5, day: 1), deviceTimeZone: newYork)[0]
        let skip = RoutinePlanner.log(.skipped, planned: p, userId: user, at: p.scheduledAt, timeZone: newYork)
        #expect(skip.dose == nil && skip.takenAt == nil && skip.occurrenceKey == p.occurrenceKey)
        let take = RoutinePlanner.log(.taken, planned: p, userId: user, at: p.scheduledAt, timeZone: newYork)
        #expect(take.dose == p.dose && take.takenAt == p.scheduledAt && take.timeZoneIdentifier == "America/New_York")
    }
}
