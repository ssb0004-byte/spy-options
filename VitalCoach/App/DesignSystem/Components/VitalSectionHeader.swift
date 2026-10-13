import SwiftUI

struct VitalSectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).vitalFont(.section).foregroundStyle(VitalColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
            }
            Spacer(minLength: VitalSpacing.xs)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .vitalFont(.secondary)
                    .fontWeight(.semibold)
                    .foregroundStyle(VitalColors.accentStrong)
                    .frame(minHeight: VitalMetrics.minTouchTarget)
            }
        }
    }
}

#Preview {
    VitalSectionHeader(title: "Today's routine", subtitle: "3 of 5 logged", actionTitle: "See all") {}
        .padding()
        .vitalScreenBackground()
}
