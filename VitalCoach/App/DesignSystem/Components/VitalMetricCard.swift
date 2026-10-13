import SwiftUI

/// Direction of a change and whether that direction is good for this user's goal.
struct VitalTrend: Hashable {
    enum Direction { case up, down, flat }
    var direction: Direction
    var text: String                 // "−0.6 kg this week"
    var isFavorable: Bool?           // nil → neutral (no judgement)

    var icon: String {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }

    var color: Color {
        switch isFavorable {
        case .some(true): VitalColors.success
        case .some(false): VitalColors.caution
        case .none: VitalColors.textSecondary
        }
    }
}

/// Small line chart drawn from raw values (no axes). Decorative; the card's text carries the data.
struct VitalSparkline: View {
    var values: [Double]
    var color: Color = VitalColors.accent

    var body: some View {
        GeometryReader { geo in
            let pts = points(in: geo.size)
            ZStack {
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: pts.last!.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.22), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let last = pts.last {
                    Circle().fill(color).frame(width: 6, height: 6).position(last)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func points(in size: CGSize) -> [CGPoint] {
        guard values.count > 1, let lo = values.min(), let hi = values.max() else { return [] }
        let span = max(hi - lo, 0.0001)
        let inset: CGFloat = 4
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * size.width,
                    y: inset + (1 - CGFloat((v - lo) / span)) * (size.height - inset * 2))
        }
    }
}

struct VitalMetricCard: View {
    var title: String
    var value: String
    var unit: String? = nil
    var systemImage: String? = nil
    var trend: VitalTrend? = nil
    var caption: String? = nil       // "Arboleaf · 7:12 AM"
    var badge: String? = nil         // "Estimate"
    var sparkline: [Double] = []
    var large = false

    var body: some View {
        VitalCard {
            HStack(spacing: VitalSpacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(VitalColors.accent).accessibilityHidden(true)
                }
                Text(title).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge).vitalFont(.caption).foregroundStyle(VitalColors.info)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(VitalColors.info.opacity(0.12), in: Capsule())
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: VitalSpacing.xxs) {
                Text(value).vitalFont(large ? .metricLarge : .metric).foregroundStyle(VitalColors.textPrimary)
                    .minimumScaleFactor(0.6).lineLimit(1)
                if let unit {
                    Text(unit).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
            }
            if !sparkline.isEmpty {
                VitalSparkline(values: sparkline).frame(height: 36)
            }
            if let trend {
                Label(trend.text, systemImage: trend.icon)
                    .vitalFont(.caption)
                    .foregroundStyle(trend.color)
            }
            if let caption {
                Text(caption).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Metric cards") {
    LazyVGrid(columns: [GridItem(.flexible(), spacing: VitalSpacing.s), GridItem(.flexible())], spacing: VitalSpacing.s) {
        VitalMetricCard(title: "Weight", value: "182.4", unit: "lb", systemImage: "scalemass",
                        trend: VitalTrend(direction: .down, text: "−1.2 lb / 7 days", isFavorable: true),
                        sparkline: [184.1, 183.8, 183.9, 183.2, 183.0, 182.7, 182.4])
        VitalMetricCard(title: "Body fat", value: "21.8", unit: "%", systemImage: "percent",
                        trend: VitalTrend(direction: .flat, text: "No change", isFavorable: nil), badge: "Estimate",
                        sparkline: [22.0, 21.9, 22.1, 21.8, 21.9, 21.8, 21.8])
    }
    .padding()
    .vitalScreenBackground()
}
