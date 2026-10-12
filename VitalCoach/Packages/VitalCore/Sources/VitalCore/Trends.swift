import Foundation

/// A single point for charts. `isGapFiller` is never produced: missing days are simply absent,
/// and charts render them as gaps rather than interpolating fictional values.
public struct DailyPoint: Sendable, Equatable, Identifiable {
    public var day: Date          // start of local day
    public var value: Double      // canonical units
    public var sampleCount: Int
    public var quality: MeasurementQuality
    public var id: Date { day }

    public init(day: Date, value: Double, sampleCount: Int, quality: MeasurementQuality) {
        self.day = day; self.value = value; self.sampleCount = sampleCount; self.quality = quality
    }
}

public struct TrendSummary: Sendable, Equatable {
    public var latest: Double?
    public var latestDate: Date?
    public var first: Double?
    public var change: Double?
    /// Least-squares slope in canonical units per 7 days. Nil when fewer than `minimumPoints`.
    public var slopePerWeek: Double?
    public var dayCount: Int
    public var daysWithData: Int
    /// Fraction of days in the window that have at least one value.
    public var coverage: Double
    public var isSufficient: Bool
}

public enum TrendCalculator {
    public static let minimumPoints = 3

    /// Collapses samples into one value per local day.
    /// Cumulative metrics sum within a day; others average. The quality of a day is the
    /// "weakest" quality among its samples (estimated beats measured, etc.).
    ///
    /// Note: summing raw HealthKit step samples double-counts when iPhone and Watch both
    /// record; the HealthKit layer uses statistics queries for cumulative metrics instead.
    public static func daily(_ samples: [HealthMeasurement], calendar: Calendar) -> [DailyPoint] {
        let live = samples.filter { !$0.isDeleted }
        let grouped = Dictionary(grouping: live) { calendar.startOfDay(for: $0.startAt) }
        return grouped.map { day, items in
            let values = items.map(\.value)
            let cumulative = items.first?.kind.isCumulative ?? false
            let v = cumulative ? values.reduce(0, +) : values.reduce(0, +) / Double(values.count)
            return DailyPoint(day: day, value: v, sampleCount: items.count, quality: weakest(items.map(\.quality)))
        }.sorted { $0.day < $1.day }
    }

    static func weakest(_ qualities: [MeasurementQuality]) -> MeasurementQuality {
        let order: [MeasurementQuality] = [.selfReported, .derived, .estimated, .measured]
        return order.first(where: qualities.contains) ?? .measured
    }

    /// Trailing moving average over `window` calendar days (only real days contribute).
    public static func movingAverage(_ points: [DailyPoint], windowDays: Int, calendar: Calendar) -> [DailyPoint] {
        points.map { p in
            guard let start = calendar.date(byAdding: .day, value: -(windowDays - 1), to: p.day) else { return p }
            let window = points.filter { $0.day >= start && $0.day <= p.day }
            let avg = window.map(\.value).reduce(0, +) / Double(window.count)
            return DailyPoint(day: p.day, value: avg, sampleCount: window.reduce(0) { $0 + $1.sampleCount }, quality: p.quality)
        }
    }

    public static func summarize(_ points: [DailyPoint], from start: Date, to end: Date, calendar: Calendar) -> TrendSummary {
        let s = calendar.startOfDay(for: start)
        let e = calendar.startOfDay(for: end)
        let inRange = points.filter { $0.day >= s && $0.day <= e }.sorted { $0.day < $1.day }
        let dayCount = (calendar.dateComponents([.day], from: s, to: e).day ?? 0) + 1
        let slope = inRange.count >= minimumPoints ? slopePerWeek(inRange) : nil
        return TrendSummary(
            latest: inRange.last?.value, latestDate: inRange.last?.day, first: inRange.first?.value,
            change: inRange.count >= 2 ? inRange.last!.value - inRange.first!.value : nil,
            slopePerWeek: slope, dayCount: max(dayCount, 0), daysWithData: inRange.count,
            coverage: dayCount > 0 ? Double(inRange.count) / Double(dayCount) : 0,
            isSufficient: inRange.count >= minimumPoints)
    }

    /// Ordinary least squares slope, x in days, scaled to per-week.
    public static func slopePerWeek(_ points: [DailyPoint]) -> Double? {
        guard points.count >= 2, let t0 = points.first?.day else { return nil }
        let xs = points.map { $0.day.timeIntervalSince(t0) / 86_400 }
        let ys = points.map(\.value)
        let n = Double(points.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var num = 0.0, den = 0.0
        for (x, y) in zip(xs, ys) { num += (x - mx) * (y - my); den += (x - mx) * (x - mx) }
        guard den > 0 else { return nil }
        return num / den * 7
    }

    /// Ranges of consecutive missing days of at least `minimumGapDays`, for data-gap callouts.
    public static func gaps(_ points: [DailyPoint], from start: Date, to end: Date, minimumGapDays: Int, calendar: Calendar) -> [ClosedRange<Date>] {
        let have = Set(points.map(\.day))
        var result: [ClosedRange<Date>] = []
        var gapStart: Date?
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        var gapLength = 0
        while day <= last {
            if have.contains(day) {
                if let g = gapStart, gapLength >= minimumGapDays,
                   let prev = calendar.date(byAdding: .day, value: -1, to: day) { result.append(g...prev) }
                gapStart = nil; gapLength = 0
            } else {
                if gapStart == nil { gapStart = day }
                gapLength += 1
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        if let g = gapStart, gapLength >= minimumGapDays { result.append(g...last) }
        return result
    }
}

/// Picks the value to show on the dashboard for a metric when multiple sources exist.
public enum SourcePreference {
    /// Prefers device data over manual for the same day, newest first; never mixes values.
    public static func latest(_ samples: [HealthMeasurement]) -> HealthMeasurement? {
        samples.filter { !$0.isDeleted }.max { a, b in
            if a.startAt != b.startAt { return a.startAt < b.startAt }
            return rank(a.sourceKind) < rank(b.sourceKind)
        }
    }

    static func rank(_ k: MeasurementSourceKind) -> Int {
        switch k { case .healthKit: 2; case .manual: 1; case .derived: 0 }
    }
}
