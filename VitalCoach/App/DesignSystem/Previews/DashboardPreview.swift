import SwiftUI
import VitalCore

/// Static dashboard mock-up for founder review. Uses sample data only and isn't wired into the
/// app; the real Home screen is migrated after the design is approved.
struct DashboardPreview: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VitalSpacing.l) {
                header
                VitalInsightCard(title: "Steady progress this week",
                                 message: "Your 7-day average weight is down 1.2 lb and resting heart rate held steady. Sleep was shorter on the two days you reported the most knee soreness.",
                                 basis: "Based on 7 weigh-ins and 6 check-ins · Oct 6–12") {
                    HStack(spacing: VitalSpacing.xs) {
                        VitalButton(title: "Ask the coach", systemImage: "bubble.left.and.text.bubble.right") {}
                        VitalButton(title: "Details", kind: .secondary) {}
                    }
                }
                VitalSectionHeader(title: "Your metrics", actionTitle: "Trends") {}
                LazyVGrid(columns: [GridItem(.flexible(), spacing: VitalSpacing.s), GridItem(.flexible())], spacing: VitalSpacing.s) {
                    VitalMetricCard(title: "Weight", value: "182.4", unit: "lb", systemImage: "scalemass",
                                    trend: VitalTrend(direction: .down, text: "−1.2 lb · 7 d", isFavorable: true),
                                    caption: "Arboleaf · 7:12 AM", sparkline: [184.1, 183.8, 183.9, 183.2, 183.0, 182.7, 182.4])
                    VitalMetricCard(title: "Body fat", value: "21.8", unit: "%", systemImage: "percent",
                                    trend: VitalTrend(direction: .flat, text: "Stable · 7 d", isFavorable: nil),
                                    caption: "Arboleaf · Estimate", badge: "Est.", sparkline: [22.0, 21.9, 22.1, 21.8, 21.9, 21.8, 21.8])
                    VitalMetricCard(title: "Resting HR", value: "58", unit: "bpm", systemImage: "heart",
                                    trend: VitalTrend(direction: .down, text: "−2 bpm · 30 d", isFavorable: true),
                                    caption: "Apple Watch", sparkline: [61, 60, 60, 59, 59, 58, 58])
                    VitalMetricCard(title: "Steps", value: "8,412", systemImage: "figure.walk",
                                    trend: VitalTrend(direction: .up, text: "+9% vs avg", isFavorable: true),
                                    caption: "Today", sparkline: [6200, 7400, 9100, 5600, 8800, 7900, 8412])
                }
                VitalSectionHeader(title: "Today's routine", subtitle: "2 of 4 logged")
                VitalCard {
                    VitalProgressIndicator(value: 0.5, label: "Doses logged today")
                    routineRow("Metformin", "500 mg · Oral · 8:00 AM", .prescription, .success, "Taken 8:04")
                    Divider().overlay(VitalColors.border)
                    routineRow("Vitamin D3", "2,000 IU · Oral · 8:00 AM", .vitaminMineral, .success, "Taken 8:04")
                    Divider().overlay(VitalColors.border)
                    routineRow("Magnesium", "1 capsule · Oral · 9:00 PM", .vitaminMineral, .neutral, "Upcoming")
                    Divider().overlay(VitalColors.border)
                    routineRow("Creatine", "5 g · Oral · Any time", .sportsSupplement, .caution, "Not logged")
                }
                VitalCard {
                    HStack(spacing: VitalSpacing.m) {
                        VitalProgressIndicator(value: 0.86, label: "Check-ins", style: .ring).frame(width: 84, height: 84)
                        VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                            Text("Daily check-in").vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                            Text("Under a minute. 6 of the last 7 days.").vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                            VitalButton(title: "Start check-in", kind: .secondary) {}.padding(.top, VitalSpacing.xxs)
                        }
                    }
                }
            }
            .padding(.horizontal, VitalSpacing.page)
            .padding(.bottom, VitalSpacing.xl)
        }
        .vitalScreenBackground()
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Monday, October 13").vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                Text("Good morning, Alex").vitalFont(.title).foregroundStyle(VitalColors.textPrimary)
            }
            Spacer()
            VitalLogoMark(size: 36)
        }
        .padding(.top, VitalSpacing.m)
    }

    private func routineRow(_ name: String, _ detail: String, _ cat: SubstanceCategory, _ status: VitalStatusIndicator.Status, _ text: String) -> some View {
        VitalSubstanceRow(name: name, detail: detail, category: cat) {
            VitalStatusIndicator(status: status, text: text, compact: true)
        }
    }
}

#Preview("Dashboard · Light") {
    DashboardPreview().preferredColorScheme(.light)
}

#Preview("Dashboard · Dark") {
    DashboardPreview().preferredColorScheme(.dark)
}

#Preview("Dashboard · Largest text") {
    DashboardPreview().environment(\.dynamicTypeSize, .accessibility2)
}
