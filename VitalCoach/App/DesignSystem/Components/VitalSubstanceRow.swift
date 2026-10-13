import SwiftUI
import VitalCore

extension SubstanceCategory {
    /// SF Symbol per category (shared by the routine list, search and category cards).
    var symbolName: String {
        switch self {
        case .prescription: "cross.case"
        case .overTheCounter: "pills"
        case .vitaminMineral: "leaf"
        case .sportsSupplement: "figure.strengthtraining.traditional"
        case .peptide: "syringe"
        case .hormone: "waveform.path.ecg"
        case .compounded: "flask"
        case .other: "circle.grid.2x2"
        }
    }
}

/// One substance in a list: category icon, name, detail line and an origin badge.
struct VitalSubstanceRow<Trailing: View>: View {
    enum Origin { case verified, userCreated, unknown }

    var name: String
    var detail: String?
    var category: SubstanceCategory
    var origin: Origin = .unknown
    var note: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: VitalSpacing.s) {
            Image(systemName: category.symbolName)
                .font(.body.weight(.medium))
                .foregroundStyle(VitalColors.accent)
                .frame(width: 40, height: 40)
                .background(VitalColors.accentMuted, in: RoundedRectangle(cornerRadius: VitalRadii.small, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: VitalSpacing.xxs) {
                    Text(name).vitalFont(.cardTitle).foregroundStyle(VitalColors.textPrimary)
                    switch origin {
                    case .verified:
                        Image(systemName: "checkmark.seal.fill").imageScale(.small).foregroundStyle(VitalColors.accent)
                            .accessibilityLabel("Verified catalog entry")
                    case .userCreated:
                        Text("User-created").vitalFont(.caption).foregroundStyle(VitalColors.caution)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(VitalColors.caution.opacity(0.12), in: Capsule())
                    case .unknown:
                        EmptyView()
                    }
                }
                if let detail {
                    Text(detail).vitalFont(.secondary).foregroundStyle(VitalColors.textSecondary)
                }
                if let note {
                    Text(note).vitalFont(.caption).foregroundStyle(VitalColors.textSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing
        }
        .frame(minHeight: VitalMetrics.minTouchTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension VitalSubstanceRow where Trailing == EmptyView {
    init(name: String, detail: String?, category: SubstanceCategory, origin: Origin = .unknown, note: String? = nil) {
        self.init(name: name, detail: detail, category: category, origin: origin, note: note) { EmptyView() }
    }
}

#Preview {
    VitalCard {
        VitalSubstanceRow(name: "Metformin", detail: "500 mg · Oral · Daily 08:00", category: .prescription, origin: .verified)
        Divider().overlay(VitalColors.border)
        VitalSubstanceRow(name: "Clinic recovery blend", detail: "Subcutaneous · Mon, Wed, Fri", category: .compounded, origin: .userCreated)
    }
    .padding()
    .vitalScreenBackground()
}
