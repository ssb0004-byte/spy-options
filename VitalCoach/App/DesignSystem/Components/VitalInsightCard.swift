import SwiftUI

/// Featured coach insight ("Your VitalCoach Insight"). Shows what the statement is based on.
struct VitalInsightCard<Actions: View>: View {
    var eyebrow: String = "Your VitalCoach Insight"
    var title: String
    var message: String
    var basis: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VitalCard(style: .featured, padding: VitalSpacing.l) {
            HStack(spacing: VitalSpacing.xs) {
                VitalLogoMark(size: 22, style: .brand)
                Text(eyebrow.uppercased())
                    .vitalFont(.caption)
                    .tracking(0.8)
                    .foregroundStyle(VitalColors.accentStrong)
            }
            .accessibilityElement(children: .combine)
            Text(title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(message).vitalFont(.body).foregroundStyle(VitalColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if let basis {
                Label(basis, systemImage: "chart.line.text.clipboard")
                    .vitalFont(.caption)
                    .foregroundStyle(VitalColors.textSecondary)
            }
            actions
        }
    }
}

extension VitalInsightCard where Actions == EmptyView {
    init(eyebrow: String = "Your VitalCoach Insight", title: String, message: String, basis: String? = nil) {
        self.init(eyebrow: eyebrow, title: title, message: message, basis: basis) { EmptyView() }
    }
}

#Preview {
    VitalInsightCard(title: "Steady progress this week",
                     message: "Your 7-day average weight is down 1.2 lb while resting heart rate held steady. Sleep was shorter on the two days you logged the most soreness.",
                     basis: "Based on 7 weigh-ins, 6 check-ins · Oct 6–12") {
        HStack {
            VitalButton(title: "Ask the coach", systemImage: "bubble.left", kind: .primary) {}
        }
    }
    .padding()
    .vitalScreenBackground()
}
