import SwiftUI
import UIKit
import VitalCore

/// Shared building blocks used by the feature screens. Since the VitalCoach Health redesign,
/// these keep their original APIs (so screen behaviour is unchanged) but draw with the design
/// tokens in `DesignSystem/Theme`.
enum Theme {
    static let accent = VitalColors.accent
    static let cardBackground = VitalColors.card
    static let pageBackground = VitalColors.background
    static let cornerRadius: CGFloat = VitalRadii.card

    enum Spacing {
        static let xs: CGFloat = VitalSpacing.xxs
        static let s: CGFloat = VitalSpacing.xs
        static let m: CGFloat = VitalSpacing.s
        static let l: CGFloat = VitalSpacing.m
        static let xl: CGFloat = VitalSpacing.l
    }

    /// App-wide UIKit appearance (navigation bar titles, tab bar, segmented controls) so system
    /// chrome uses the VitalCoach type colours. Called once at launch.
    @MainActor static func applyAppearance() {
        let nav = UINavigationBarAppearance()
        nav.configureWithTransparentBackground()
        nav.backgroundColor = UIColor(VitalColors.background)
        nav.shadowColor = .clear
        let primary = UIColor(VitalColors.textPrimary)
        nav.titleTextAttributes = [.foregroundColor: primary, .font: UIFont.systemFont(ofSize: 17, weight: .semibold)]
        nav.largeTitleTextAttributes = [.foregroundColor: primary, .font: UIFont.systemFont(ofSize: 32, weight: .bold)]
        let scrolled = UINavigationBarAppearance()
        scrolled.configureWithDefaultBackground()
        scrolled.titleTextAttributes = nav.titleTextAttributes
        scrolled.largeTitleTextAttributes = nav.largeTitleTextAttributes
        UINavigationBar.appearance().standardAppearance = scrolled
        UINavigationBar.appearance().compactAppearance = scrolled
        UINavigationBar.appearance().scrollEdgeAppearance = nav

        UISegmentedControl.appearance().selectedSegmentTintColor = UIColor(VitalColors.card)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: UIColor(VitalColors.textSecondary)], for: .normal)
        UISegmentedControl.appearance().setTitleTextAttributes([.foregroundColor: primary], for: .selected)
    }
}

extension View {
    /// Brand background for `List` / `Form` screens: hides the system grouped background and
    /// uses the VitalCoach page colour. Pair with `.vitalRow()` on sections.
    func vitalListBackground() -> some View {
        scrollContentBackground(.hidden).background(VitalColors.background.ignoresSafeArea())
    }

    /// Card-coloured row background for `List` / `Form` sections.
    func vitalRow() -> some View {
        listRowBackground(VitalColors.card)
    }
}

/// Grouped card container used across Home, Routine and Trends.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VitalCard {
            if let title {
                Label {
                    Text(title).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                } icon: {
                    Image(systemName: systemImage ?? "circle").foregroundStyle(VitalColors.accent)
                }
                .accessibilityAddTraits(.isHeader)
            }
            content
        }
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
        VitalEmptyState(title: title, message: message, systemImage: systemImage, actionTitle: actionTitle, action: action)
    }
}

/// Shows how trustworthy a value is: measured, estimated, self-reported or derived.
struct QualityBadge: View {
    var quality: MeasurementQuality

    var body: some View {
        Text(label)
            .vitalFont(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
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
        case .measured: VitalColors.accentStrong
        case .estimated: VitalColors.info
        case .selfReported: VitalColors.caution
        case .derived: VitalColors.textSecondary
        }
    }
}

struct MetricTile: View {
    var title: String
    var value: String
    var detail: String?
    var quality: MeasurementQuality?

    var body: some View {
        VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
            Text(title).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(VitalColors.textPrimary)
                .minimumScaleFactor(0.7).lineLimit(1)
            HStack(spacing: VitalSpacing.xxs) {
                if let quality { QualityBadge(quality: quality) }
                if let detail { Text(detail).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary).lineLimit(1) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// Inline banner for errors and notices. Icon + text, never colour alone.
struct NoticeBanner: View {
    enum Style { case info, warning, critical }
    var style: Style
    var text: String

    var body: some View {
        Label {
            Text(text).vitalFont(.secondary).foregroundStyle(VitalColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .padding(VitalSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch style {
        case .info: "info.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "cross.case.fill"
        }
    }

    private var color: Color {
        switch style {
        case .info: VitalColors.info
        case .warning: VitalColors.caution
        case .critical: VitalColors.critical
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
        VStack(alignment: .leading, spacing: VitalSpacing.xs) {
            Text(title).vitalFont(.body).fontWeight(.medium).foregroundStyle(VitalColors.textPrimary)
            HStack(spacing: 6) {
                ForEach(Array(range), id: \.self) { n in
                    let selected = value == n
                    Button {
                        value = selected ? nil : n
                    } label: {
                        Text("\(n)")
                            .font(.callout.weight(selected ? .bold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(selected ? VitalColors.onAccent : VitalColors.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: VitalMetrics.minTouchTarget)
                            .background(selected ? VitalColors.accentStrong : VitalColors.surfaceSecondary,
                                        in: RoundedRectangle(cornerRadius: VitalRadii.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                }
            }
            HStack {
                Text(lowLabel); Spacer(); Text(highLabel)
            }
            .vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
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
