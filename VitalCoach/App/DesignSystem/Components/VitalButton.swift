import SwiftUI

/// Button styles: primary (filled teal), secondary (tinted), tertiary (text), destructive.
struct VitalButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tertiary, destructive }
    var kind: Kind = .primary
    var fullWidth = true

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .vitalFont(.cardTitle)
            .multilineTextAlignment(.center)
            .padding(.horizontal, VitalSpacing.m)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: kind == .tertiary ? VitalMetrics.minTouchTarget : VitalMetrics.buttonHeight)
            .foregroundStyle(foreground)
            .background(background, in: RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous)
                        .strokeBorder(VitalColors.accent.opacity(0.35), lineWidth: 1)
                }
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(VitalMotion.standard(reduceMotion: reduceMotion), value: configuration.isPressed)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: VitalColors.onAccent
        case .secondary, .tertiary: VitalColors.accentStrong
        case .destructive: VitalColors.critical
        }
    }

    private var background: Color {
        switch kind {
        case .primary: VitalColors.accentStrong
        case .secondary: VitalColors.accentMuted
        case .tertiary: .clear
        case .destructive: VitalColors.critical.opacity(0.12)
        }
    }
}

/// Convenience wrapper with an optional SF Symbol and loading state.
struct VitalButton: View {
    var title: String
    var systemImage: String? = nil
    var kind: VitalButtonStyle.Kind = .primary
    var isLoading = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: VitalSpacing.xs) {
                if isLoading {
                    ProgressView().tint(kind == .primary ? VitalColors.onAccent : VitalColors.accent)
                } else if let systemImage {
                    Image(systemName: systemImage).accessibilityHidden(true)
                }
                Text(title)
            }
        }
        .buttonStyle(VitalButtonStyle(kind: kind))
        .disabled(isLoading)
        .accessibilityValue(isLoading ? "Loading" : "")
    }
}

#Preview("Buttons") {
    VStack(spacing: VitalSpacing.s) {
        VitalButton(title: "Log dose", systemImage: "checkmark") {}
        VitalButton(title: "Saving…", isLoading: true) {}
        VitalButton(title: "Add measurement", systemImage: "plus", kind: .secondary) {}
        VitalButton(title: "Not now", kind: .tertiary) {}
        VitalButton(title: "Delete", systemImage: "trash", kind: .destructive) {}
        VitalButton(title: "Disabled") {}.disabled(true)
    }
    .padding()
    .vitalScreenBackground()
}
