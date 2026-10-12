import SwiftUI
import VitalCore

/// Restrained, Apple-native styling. Colors are semantic system colors so light/dark mode and
/// Increase Contrast work automatically; spacing uses a small fixed scale.
enum Theme {
    static let accent = Color.teal
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cornerRadius: CGFloat = 16

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }
}

/// Grouped card container used across Home, Routine and Trends.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            if let title {
                Label(title, systemImage: systemImage ?? "circle")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
            }
            content
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// Accessible empty state with an optional call to action.
struct EmptyStateView: View {
    var title: String
    var message: String
    var systemImage: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Shows how trustworthy a value is: measured, estimated, self-reported or derived.
struct QualityBadge: View {
    var quality: MeasurementQuality

    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Data quality: \(label)")
    }

    var label: String {
        switch quality {
        case .measured: "Measured"
        case .estimated: "Estimate"
        case .selfReported: "Self-reported"
        case .derived: "Calculated"
        }
    }

    var color: Color {
        switch quality {
        case .measured: .teal
        case .estimated: .orange
        case .selfReported: .indigo
        case .derived: .gray
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var detail: String?
    var quality: MeasurementQuality?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .minimumScaleFactor(0.7).lineLimit(1)
            HStack(spacing: Theme.Spacing.xs) {
                if let quality { QualityBadge(quality: quality) }
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Inline banner for errors and notices.
struct NoticeBanner: View {
    enum Style { case info, warning, critical }
    var style: Style
    var text: String

    var body: some View {
        Label {
            Text(text).font(.footnote).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch style {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "cross.case"
        }
    }

    private var color: Color {
        switch style {
        case .info: .blue
        case .warning: .orange
        case .critical: .red
        }
    }
}

/// A 1–5 or 0–10 rating control that works with VoiceOver (adjustable action).
struct ScaleRating: View {
    var title: String
    var range: ClosedRange<Int>
    var lowLabel: String
    var highLabel: String
    @Binding var value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title).font(.subheadline.weight(.medium))
            HStack(spacing: 6) {
                ForEach(Array(range), id: \.self) { n in
                    Button {
                        value = (value == n) ? nil : n
                    } label: {
                        Text("\(n)")
                            .font(.callout.weight(value == n ? .bold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(value == n ? Theme.accent.opacity(0.25) : Color(uiColor: .tertiarySystemFill),
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            HStack {
                Text(lowLabel); Spacer(); Text(highLabel)
            }
            .font(.caption2).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0) of \(range.upperBound)" } ?? "Not answered")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min((value ?? range.lowerBound - 1) + 1, range.upperBound)
            case .decrement: value = max((value ?? range.lowerBound + 1) - 1, range.lowerBound)
            @unknown default: break
            }
        }
    }
}
