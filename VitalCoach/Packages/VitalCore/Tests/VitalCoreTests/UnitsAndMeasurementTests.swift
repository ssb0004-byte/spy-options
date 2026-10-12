import Foundation
import Testing
@testable import VitalCore

@Suite("Units")
struct UnitsTests {
    @Test func massDoseConversionsAreExact() throws {
        let q = DoseQuantity(amount: Decimal(string: "0.25")!, unit: .milligram)
        #expect(try q.converted(to: .microgram) == DoseQuantity(amount: 250, unit: .microgram))
        #expect(try q.converted(to: .gram).amount == Decimal(string: "0.00025")!)
        #expect(try DoseQuantity(amount: 1500, unit: .microgram).converted(to: .milligram).amount == Decimal(string: "1.5")!)
    }

    @Test func volumeToMassRequiresConfirmedConcentration() throws {
        let ml = DoseQuantity(amount: Decimal(string: "0.5")!, unit: .milliliter)
        #expect(throws: DoseConversionError.requiresConcentration(from: .milliliter, to: .milligram)) {
            try ml.converted(to: .milligram)
        }
        // 200 mg/mL × 0.5 mL = 100 mg
        let mg = try ml.converted(to: .milligram, concentrationPerML: DoseQuantity(amount: 200, unit: .milligram))
        #expect(mg == DoseQuantity(amount: 100, unit: .milligram))
    }

    @Test func potencyUnitsAreNeverConverted() {
        #expect(throws: DoseConversionError.notConvertible(from: .internationalUnit, to: .microgram)) {
            try DoseQuantity(amount: 1000, unit: .internationalUnit).converted(to: .microgram)
        }
        #expect(throws: DoseConversionError.notConvertible(from: .unit, to: .internationalUnit)) {
            try DoseQuantity(amount: 10, unit: .unit).converted(to: .internationalUnit)
        }
        #expect(throws: DoseConversionError.notConvertible(from: .capsule, to: .milligram)) {
            try DoseQuantity(amount: 1, unit: .capsule).converted(to: .milligram)
        }
    }

    @Test(arguments: [
        ("0.25", Decimal(string: "0.25")), ("1/2", Decimal(string: "0.5")), ("2", Decimal(2)),
        ("1,5", Decimal(string: "1.5")), (" 10 ", Decimal(10)),
        ("", nil), ("abc", nil), ("-1", nil), ("0", nil), ("1/0", nil), ("1.2.3", nil),
    ])
    func parsesDoseAmounts(input: String, expected: Decimal?) {
        #expect(DoseQuantity.parseAmount(input, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func bodyUnitsRoundTrip() {
        #expect(abs(MassUnit.pound.toKilograms(220) - 99.79032140) < 1e-6)
        #expect(abs(MassUnit.pound.fromKilograms(MassUnit.pound.toKilograms(181.4)) - 181.4) < 1e-9)
        #expect(LengthUnit.inch.toCentimeters(34) == 86.36)
    }

    @Test func formatsDoseWithoutFloatNoise() {
        #expect(DoseQuantity(amount: Decimal(string: "0.1")!, unit: .milligram).formatted == "0.1 mg")
        #expect(DoseQuantity(amount: 5000, unit: .internationalUnit).formatted == "5000 IU")
    }
}

@Suite("Measurements")
struct MeasurementTests {
    let user = UUID()
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func bmiIsComputedOnlyFromRealInputs() {
        #expect(abs(BodyMetrics.bmi(weightKg: 80, heightCm: 180)! - 24.691358) < 1e-5)
        #expect(BodyMetrics.bmi(weightKg: nil, heightCm: 180) == nil)
        #expect(BodyMetrics.bmi(weightKg: 80, heightCm: nil) == nil)
        #expect(BodyMetrics.bmi(weightKg: 80, heightCm: 18) == nil) // implausible height (typo)
    }

    @Test func fatFreeMassDerivation() {
        #expect(BodyMetrics.fatFreeMass(weightKg: 100, bodyFatPercent: 20) == 80)
        #expect(BodyMetrics.fatFreeMass(weightKg: 100, bodyFatPercent: 120) == nil)
    }

    @Test func manualEntryConvertsToCanonicalAndLabelsQuality() throws {
        let m = try MeasurementFactory.manual(userId: user, kind: .bodyMass, displayValue: 200, units: .imperial, at: now, now: now)
        #expect(abs(m.value - 90.718474) < 1e-6)
        #expect(m.unit == .kilogram)
        #expect(m.quality == .selfReported)
        #expect(m.sourceKind == .manual)
        let waist = try MeasurementFactory.manual(userId: user, kind: .waistCircumference, displayValue: 34, units: .imperial, at: now, now: now)
        #expect(abs(waist.value - 86.36) < 1e-9)
    }

    @Test func manualEntryRejectsTyposAndFutureDates() {
        #expect(throws: MeasurementValidationError.self) {
            try MeasurementFactory.manual(userId: user, kind: .bodyMass, displayValue: 1800, units: .metric, at: now, now: now)
        }
        #expect(throws: MeasurementValidationError.futureDate) {
            try MeasurementFactory.manual(userId: user, kind: .bodyMass, displayValue: 80, units: .metric, at: now.addingTimeInterval(86_400), now: now)
        }
        #expect(throws: MeasurementValidationError.notANumber) {
            try MeasurementFactory.manual(userId: user, kind: .bodyMass, displayValue: .nan, units: .metric, at: now, now: now)
        }
    }

    @Test func displayFormatting() {
        #expect(MetricDisplay.format(90.718474, kind: .bodyMass, units: .imperial) == "200.0 lb")
        #expect(MetricDisplay.format(8432, kind: .stepCount, units: .metric).hasSuffix("steps"))
        #expect(MetricDisplay.format(24.7, kind: .bodyMassIndex, units: .metric) == "24.7")
    }

    @Test func jsonUsesSnakeCaseColumnsAndRoundTrips() throws {
        let m = HealthMeasurement(userId: user, kind: .bodyFatPercentage, value: 18.4, startAt: now, sourceKind: .healthKit,
                                  sourceName: "Arboleaf", externalId: "ABC", quality: .estimated, clientUpdatedAt: now)
        let data = try VitalJSON.encoder().encode(m)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"user_id\""))
        #expect(text.contains("\"external_id\":\"ABC\""))
        #expect(text.contains("\"client_updated_at\""))
        #expect(!text.contains("userId"))
        let back = try VitalJSON.decoder().decode(HealthMeasurement.self, from: data)
        #expect(back.id == m.id && back.value == m.value && back.kind == m.kind)
        #expect(abs(back.startAt.timeIntervalSince(m.startAt)) < 0.001)
    }

    @Test func decimalDosesSurviveEncoding() throws {
        let r = SubstanceRegimen(userId: user, userSubstanceId: UUID(), dose: DoseQuantity(amount: Decimal(string: "0.1")!, unit: .milligram),
                                 route: .subcutaneous, schedule: RegimenSchedule(frequency: .daily, times: [LocalTime(hour: 8, minute: 0)]),
                                 startDate: LocalDate(year: 2026, month: 3, day: 1))
        let data = try VitalJSON.encoder().encode(r)
        #expect(String(decoding: data, as: UTF8.self).contains("\"dose_amount\":0.1"))
        let back = try VitalJSON.decoder().decode(SubstanceRegimen.self, from: data)
        #expect(back.doseAmount == Decimal(string: "0.1")!)
        #expect(back.startDate.description == "2026-03-01")
    }

    @Test func parsesPostgresTimestamps() {
        #expect(ISO8601.parse("2026-03-08T09:30:00.123456+00:00") != nil)
        #expect(ISO8601.parse("2026-03-08T09:30:00+00:00") != nil)
        #expect(ISO8601.parse("2026-03-08T09:30:00.1Z") != nil)
        #expect(ISO8601.parse("not a date") == nil)
    }
}

@Suite("Trends")
struct TrendTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c
    }
    let user = UUID()

    func m(_ kind: MetricKind, _ v: Double, day: Int, hour: Int = 8, source: MeasurementSourceKind = .healthKit) -> HealthMeasurement {
        let d = cal.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour))!
        return HealthMeasurement(userId: user, kind: kind, value: v, startAt: d, sourceKind: source, quality: .measured)
    }

    @Test func dailyAggregationAveragesOrSums() {
        let weights = TrendCalculator.daily([m(.bodyMass, 80, day: 1), m(.bodyMass, 82, day: 1, hour: 20), m(.bodyMass, 81, day: 2)], calendar: cal)
        #expect(weights.map(\.value) == [81, 81])
        #expect(weights.first?.sampleCount == 2)
        let steps = TrendCalculator.daily([m(.stepCount, 3000, day: 1), m(.stepCount, 4000, day: 1, hour: 18)], calendar: cal)
        #expect(steps.map(\.value) == [7000])
    }

    @Test func deletedSamplesAreExcluded() {
        var d = m(.bodyMass, 200, day: 1); d.deletedAt = Date()
        #expect(TrendCalculator.daily([d, m(.bodyMass, 80, day: 1)], calendar: cal).map(\.value) == [80])
    }

    @Test func slopeAndSufficiency() {
        let pts = TrendCalculator.daily((1...15).map { m(.bodyMass, 90 - Double($0) * 0.1, day: $0) }, calendar: cal)
        let start = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let end = cal.date(from: DateComponents(year: 2026, month: 5, day: 15))!
        let s = TrendCalculator.summarize(pts, from: start, to: end, calendar: cal)
        #expect(s.isSufficient)
        #expect(abs(s.slopePerWeek! - (-0.7)) < 1e-9)
        #expect(s.coverage == 1)
        let sparse = TrendCalculator.summarize(Array(pts.prefix(2)), from: start, to: end, calendar: cal)
        #expect(!sparse.isSufficient)
        #expect(sparse.slopePerWeek == nil)
    }

    @Test func gapsAreReportedNotFilled() {
        let pts = TrendCalculator.daily([m(.bodyMass, 80, day: 1), m(.bodyMass, 80, day: 2), m(.bodyMass, 79, day: 9)], calendar: cal)
        let start = cal.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let end = cal.date(from: DateComponents(year: 2026, month: 5, day: 10))!
        let gaps = TrendCalculator.gaps(pts, from: start, to: end, minimumGapDays: 3, calendar: cal)
        #expect(gaps.count == 1)
        #expect(cal.component(.day, from: gaps[0].lowerBound) == 3)
        #expect(cal.component(.day, from: gaps[0].upperBound) == 8)
        #expect(pts.count == 3) // no interpolated points
    }

    @Test func movingAverageUsesOnlyRealDays() {
        let pts = TrendCalculator.daily([m(.bodyMass, 80, day: 1), m(.bodyMass, 82, day: 3)], calendar: cal)
        let ma = TrendCalculator.movingAverage(pts, windowDays: 7, calendar: cal)
        #expect(ma.map(\.value) == [80, 81])
    }

    @Test func latestPrefersDeviceOverManualAtSameTime() {
        let a = m(.bodyMass, 80, day: 1, source: .manual)
        let b = m(.bodyMass, 81, day: 1, source: .healthKit)
        #expect(SourcePreference.latest([a, b])?.value == 81)
        #expect(SourcePreference.latest([a, m(.bodyMass, 79, day: 2, source: .manual)])?.value == 79)
    }
}
