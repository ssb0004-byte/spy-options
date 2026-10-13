import SwiftUI

/// Labelled text field with a visible control boundary and a clear button.
struct VitalTextField: View {
    var label: String
    @Binding var text: String
    var prompt: String = ""
    var systemImage: String? = nil
    var message: String? = nil
    var isError = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: VitalSpacing.xxs) {
            Text(label).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
            HStack(spacing: VitalSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(VitalColors.textSecondary).accessibilityHidden(true)
                }
                TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(VitalColors.textSecondary))
                    .vitalFont(.body)
                    .foregroundStyle(VitalColors.textPrimary)
                    .focused($focused)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(VitalColors.textSecondary)
                            .frame(width: VitalMetrics.minTouchTarget, height: VitalMetrics.minTouchTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear \(label)")
                }
            }
            .padding(.leading, VitalSpacing.s)
            .frame(minHeight: VitalMetrics.buttonHeight)
            .background(VitalColors.card, in: RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VitalRadii.control, style: .continuous)
                    .strokeBorder(isError ? VitalColors.critical : (focused ? VitalColors.accent : VitalColors.borderControl),
                                  lineWidth: focused || isError ? 2 : 1)
            }
            if let message {
                Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
                    .vitalFont(.caption)
                    .foregroundStyle(isError ? VitalColors.critical : VitalColors.textSecondary)
            }
        }
    }
}

#Preview {
    @Previewable @State var a = "Metformin"
    @Previewable @State var b = ""
    VStack(spacing: VitalSpacing.m) {
        VitalTextField(label: "Search", text: $a, prompt: "Search medications", systemImage: "magnifyingglass")
        VitalTextField(label: "Dose", text: $b, prompt: "e.g. 500", message: "Enter the dose exactly as prescribed.", isError: true)
    }
    .padding()
    .vitalScreenBackground()
}
