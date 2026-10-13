import SwiftUI

/// Spacing scale (pt).
enum VitalSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    /// Horizontal page margin.
    static let page: CGFloat = 16
}

/// Corner radii (continuous corners everywhere).
enum VitalRadii {
    static let small: CGFloat = 10     // chips, badges, small fields
    static let control: CGFloat = 14   // buttons, text fields
    static let card: CGFloat = 16      // cards
    static let featured: CGFloat = 20  // featured / hero cards, sheets
}

/// Subtle elevation. Dark mode relies on surface color, not shadow.
struct VitalShadow {
    var color: Color
    var radius: CGFloat
    var y: CGFloat

    static let card = VitalShadow(color: Color(hex: 0x173F3B, opacity: 0.06), radius: 12, y: 4)
    static let raised = VitalShadow(color: Color(hex: 0x173F3B, opacity: 0.10), radius: 20, y: 8)
    static let none = VitalShadow(color: .clear, radius: 0, y: 0)
}

enum VitalShadows {
    static let card = VitalShadow.card
    static let raised = VitalShadow.raised
}

/// Minimum interactive size (Apple HIG).
enum VitalMetrics {
    static let minTouchTarget: CGFloat = 44
    static let buttonHeight: CGFloat = 50
}

/// Motion: short, calm, and off when Reduce Motion is on.
enum VitalMotion {
    static func standard(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.25)
    }
    static func emphasized(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85)
    }
}

/// Entry point for the design system, so call sites read `VitalTheme.colors.accent`, etc.
enum VitalTheme {
    typealias colors = VitalColors
    typealias spacing = VitalSpacing
    typealias radii = VitalRadii
    typealias shadows = VitalShadows
}

private struct VitalShadowModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shadow: VitalShadow
    func body(content: Content) -> some View {
        let s = scheme == .dark ? VitalShadow.none : shadow
        content.shadow(color: s.color, radius: s.radius, x: 0, y: s.y)
    }
}

extension View {
    func vitalShadow(_ shadow: VitalShadow = .card) -> some View {
        modifier(VitalShadowModifier(shadow: shadow))
    }

    /// Page background for VitalCoach screens.
    func vitalScreenBackground() -> some View {
        background(VitalColors.background.ignoresSafeArea())
    }
}
