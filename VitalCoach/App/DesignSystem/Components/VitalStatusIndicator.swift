import SwiftUI

/// Status chip. Always shows an icon and text so meaning never depends on color alone.
struct VitalStatusIndicator: View {
    enum Status { case success, caution, critical, info, neutral }

    var status: Status
    var text: String
    var compact = false

    var body: some View {
        Label {
            Text(text).vitalFont(.caption)
        } icon: {
            Image(systemName: icon).imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(color)
        .padding(.horizontal, compact ? 6 : VitalSpacing.xs)
        .padding(.vertical, compact ? 2 : VitalSpacing.xxs)
        .background(color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }

    var icon: String {
        switch status {
        case .success: "checkmark.circle.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .critical: "exclamationmark.octagon.fill"
        case .info: "info.circle.fill"
        case .neutral: "circle.dashed"
        }
    }

    var color: Color {
        switch status {
        case .success: VitalColors.success
        case .caution: VitalColors.caution
        case .critical: VitalColors.critical
        case .info: VitalColors.info
        case .neutral: VitalColors.neutral
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: VitalSpacing.xs) {
        VitalStatusIndicator(status: .success, text: "Taken 8:02 AM")
        VitalStatusIndicator(status: .caution, text: "Not logged")
        VitalStatusIndicator(status: .critical, text: "Missed")
        VitalStatusIndicator(status: .info, text: "Estimate")
        VitalStatusIndicator(status: .neutral, text: "Upcoming")
    }
    .padding()
    .vitalScreenBackground()
}
