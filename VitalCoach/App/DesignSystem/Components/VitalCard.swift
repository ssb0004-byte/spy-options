import SwiftUI

/// Base card. `.standard` is white/dark-green; `.featured` is the soft sage/mist surface used for
/// the coach insight; `.outlined` sits on secondary surfaces.
struct VitalCard<Content: View>: View {
    enum Style { case standard, featured, outlined }

    var style: Style = .standard
    var padding: CGFloat = VitalSpacing.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: VitalSpacing.s) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: shape)
            .overlay { if style != .featured { shape.strokeBorder(VitalColors.border, lineWidth: 1) } }
            .vitalShadow(style == .standard ? .card : .none)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: style == .featured ? VitalRadii.featured : VitalRadii.card, style: .continuous)
    }

    private var background: Color {
        switch style {
        case .standard, .outlined: VitalColors.card
        case .featured: VitalColors.surfaceFeatured
        }
    }
}

#Preview("Cards") {
    VStack(spacing: VitalSpacing.m) {
        VitalCard { Text("Standard card").vitalFont(.cardTitle) }
        VitalCard(style: .featured) { Text("Featured card").vitalFont(.cardTitle) }
        VitalCard(style: .outlined) { Text("Outlined card").vitalFont(.cardTitle) }
    }
    .padding()
    .vitalScreenBackground()
}
