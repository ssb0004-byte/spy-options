import SwiftUI

/// Type scale (SF Pro). Sizes are the defaults at the standard Dynamic Type size and scale with
/// the user's setting through `@ScaledMetric`, each relative to the closest system text style.
enum VitalTextStyle: CaseIterable {
    case title          // 32 bold — screen titles
    case section        // 22 semibold — section headers
    case cardTitle      // 17 semibold
    case body           // 16 regular
    case secondary      // 14 regular
    case caption        // 12 medium
    case metric         // 30 semibold, monospaced digits
    case metricLarge    // 38 semibold, monospaced digits

    var size: CGFloat {
        switch self {
        case .title: 32
        case .section: 22
        case .cardTitle: 17
        case .body: 16
        case .secondary: 14
        case .caption: 12
        case .metric: 30
        case .metricLarge: 38
        }
    }

    var weight: Font.Weight {
        switch self {
        case .title: .bold
        case .section, .cardTitle, .metric, .metricLarge: .semibold
        case .body, .secondary: .regular
        case .caption: .medium
        }
    }

    var relativeTo: Font.TextStyle {
        switch self {
        case .title: .largeTitle
        case .section: .title2
        case .cardTitle: .headline
        case .body: .body
        case .secondary: .subheadline
        case .caption: .caption
        case .metric, .metricLarge: .title
        }
    }

    /// SF Rounded for numbers gives the dashboard a softer, friendlier feel.
    var design: Font.Design {
        switch self {
        case .metric, .metricLarge: .rounded
        default: .default
        }
    }

    var usesMonospacedDigits: Bool { self == .metric || self == .metricLarge }
}

private struct VitalFontModifier: ViewModifier {
    let style: VitalTextStyle
    @ScaledMetric private var size: CGFloat

    init(style: VitalTextStyle) {
        self.style = style
        _size = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let font = Font.system(size: size, weight: style.weight, design: style.design)
        if style.usesMonospacedDigits {
            content.font(font.monospacedDigit())
        } else {
            content.font(font)
        }
    }
}

extension View {
    /// Applies a VitalCoach text style (Dynamic Type aware).
    func vitalFont(_ style: VitalTextStyle) -> some View {
        modifier(VitalFontModifier(style: style))
    }
}
