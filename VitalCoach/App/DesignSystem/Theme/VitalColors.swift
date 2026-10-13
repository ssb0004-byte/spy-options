import SwiftUI
import UIKit

/// VitalCoach Health color tokens. Every token resolves separately for light and dark mode, so
/// views never branch on the color scheme themselves.
///
/// Contrast (WCAG 2.1, measured; see docs/design/DESIGN_SYSTEM.md):
/// - Primary text: 11.6:1 light / 13.6:1 dark on cards. Secondary text: 6.0:1 / 8.2:1.
/// - Brand teal #328577 on white is 4.4:1, which is enough for large text, icons and charts but
///   just under AA (4.5:1) for small text. Small accent text and primary-button fills therefore
///   use `accentStrong` (#2B7366, 5.6:1 with white).
enum VitalColors {
    // MARK: Brand palette (fixed, used by the logo and icon)
    static let primaryTeal = Color(hex: 0x328577)
    static let deepForest = Color(hex: 0x173F3B)
    static let softSage = Color(hex: 0xB8D4C5)
    static let warmIvory = Color(hex: 0xF7F9F6)
    static let mistGreen = Color(hex: 0xE8F2EC)
    static let slate = Color(hex: 0x536763)

    // MARK: Surfaces
    static let background = Color(light: 0xF7F9F6, dark: 0x101B19)
    static let card = Color(light: 0xFFFFFF, dark: 0x1B2B28)
    static let surfaceSecondary = Color(light: 0xE8F2EC, dark: 0x243B35)
    /// Featured "insight" surface (soft sage / mist).
    static let surfaceFeatured = Color(light: 0xE8F2EC, dark: 0x243B35)

    // MARK: Text
    static let textPrimary = Color(light: 0x173F3B, dark: 0xF2F7F4)
    static let textSecondary = Color(light: 0x536763, dark: 0xB1C6BC)
    /// Text on `accentStrong` fills (primary buttons).
    static let onAccent = Color(light: 0xFFFFFF, dark: 0x101B19)

    // MARK: Accent
    /// Brand accent: icons, large text, charts, selection, focus.
    static let accent = Color(light: 0x328577, dark: 0x75C4B0)
    /// Accent for small text and button fills where 4.5:1 is required.
    static let accentStrong = Color(light: 0x2B7366, dark: 0x75C4B0)
    static let accentMuted = Color(light: 0xE8F2EC, dark: 0x355B50)

    // MARK: Lines
    /// Decorative separators and card outlines.
    static let border = Color(light: 0xDCE7E0, dark: 0x365047)
    /// Boundaries that identify a control (text fields), ≥3:1 per WCAG 1.4.11.
    static let borderControl = Color(light: 0x6A8178, dark: 0x6E8F84)

    // MARK: Semantic states — always paired with an icon or label, never color alone
    static let success = Color(light: 0x1E7A46, dark: 0x6FCF97)
    static let caution = Color(light: 0x8A5A00, dark: 0xF2C46D)
    static let critical = Color(light: 0xB3261E, dark: 0xFF8A80)
    static let info = Color(light: 0x2F6690, dark: 0x8AB8E6)
    static let neutral = textSecondary

    // MARK: Charts — categorical palette, each ≥3:1 against cards in both modes
    static let chart: [Color] = [
        Color(light: 0x328577, dark: 0x75C4B0),   // teal
        Color(light: 0x5457C2, dark: 0xA9A6F5),   // indigo
        Color(light: 0xB86E00, dark: 0xF2B35E),   // amber
        Color(light: 0xB8436A, dark: 0xF28CAB),   // rose
        Color(light: 0x2479B0, dark: 0x7CC0EE),   // sky
        Color(light: 0x536763, dark: 0xB1C6BC),   // slate
    ]
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }

    /// A color that resolves per trait collection (light / dark).
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}
