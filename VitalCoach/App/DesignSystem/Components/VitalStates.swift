import SwiftUI

/// Empty state with an optional call to action.
struct VitalEmptyState: View {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: VitalSpacing.s) {
            Image(systemName: systemImage)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VitalColors.accent)
                .frame(width: 64, height: 64)
                .background(VitalColors.accentMuted, in: Circle())
                .accessibilityHidden(true)
            Text(title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(message).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                VitalButton(title: actionTitle, kind: .primary, action: action)
                    .frame(maxWidth: 280)
                    .padding(.top, VitalSpacing.xs)
            }
        }
        .padding(VitalSpacing.l)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Loading placeholder. Pulses gently unless Reduce Motion is on.
struct VitalLoadingState: View {
    var text: String = "Loading…"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: VitalSpacing.s) {
            ProgressView().tint(VitalColors.accent)
            Text(text).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
        }
        .padding(VitalSpacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VitalColors.surfaceSecondary.opacity(pulse ? 0.6 : 1),
                    in: RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous))
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Linear or ring progress, with the value announced as a percentage.
struct VitalProgressIndicator: View {
    enum Style { case linear, ring }
    var value: Double            // 0...1
    var label: String
    var style: Style = .linear
    var tint: Color = VitalColors.accent

    private var clamped: Double { min(max(value, 0), 1) }

    var body: some View {
        Group {
            switch style {
            case .linear:
                VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
                    HStack {
                        Text(label).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                        Spacer()
                        Text(clamped, format: .percent.precision(.fractionLength(0)))
                            .vitalFont(.caption).monospacedDigit().foregroundStyle(VitalColors.textPrimary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(VitalColors.surfaceSecondary)
                            Capsule().fill(tint).frame(width: geo.size.width * clamped)
                        }
                    }
                    .frame(height: 8)
                }
            case .ring:
                ZStack {
                    Circle().stroke(VitalColors.surfaceSecondary, lineWidth: 8)
                    Circle().trim(from: 0, to: clamped)
                        .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text(clamped, format: .percent.precision(.fractionLength(0)))
                            .vitalFont(.cardTitle).monospacedDigit().foregroundStyle(VitalColors.textPrimary)
                        Text(label).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .padding(VitalSpacing.xs)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(Text(clamped, format: .percent.precision(.fractionLength(0))))
    }
}

/// Card that hosts a Swift Charts chart with a title, subtitle and legend.
struct VitalChartContainer<Chart: View>: View {
    var title: String
    var subtitle: String? = nil
    var legend: [(String, Color)] = []
    @ViewBuilder var chart: Chart

    var body: some View {
        VitalCard {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                }
            }
            chart.frame(minHeight: 160)
            if !legend.isEmpty {
                HStack(spacing: VitalSpacing.s) {
                    ForEach(legend.indices, id: \.self) { i in
                        HStack(spacing: VitalSpacing.xxs) {
                            // Shape + text, so series aren't identified by color alone.
                            RoundedRectangle(cornerRadius: 2).fill(legend[i].1).frame(width: 12, height: 4)
                            Text(legend[i].0).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                        }
                    }
                }
            }
        }
    }
}

#Preview("States") {
    ScrollView {
        VStack(spacing: VitalSpacing.m) {
            VitalEmptyState(title: "Your routine is empty", message: "Add medications or supplements to log doses.",
                            systemImage: "pills", actionTitle: "Add to routine") {}
            VitalLoadingState(text: "Preparing your briefing…")
            VitalCard {
                VitalProgressIndicator(value: 0.6, label: "Doses logged today")
                VitalProgressIndicator(value: 0.75, label: "Goal", style: .ring).frame(width: 96, height: 96)
            }
            VitalChartContainer(title: "Weight", subtitle: "Last 30 days", legend: [("Daily", VitalColors.chart[0]), ("7-day avg", VitalColors.chart[1])]) {
                VitalSparkline(values: [184, 183.6, 183.9, 183.1, 182.8, 182.9, 182.4])
            }
        }
        .padding()
    }
    .vitalScreenBackground()
}
