import SwiftUI

/// Concept A — interlocking "VC" monogram (recommended). The V passes over the C at the top
/// left and under it on the right. Geometry matches docs/design/logos/concept-a-interlocking.svg
/// (100 × 100 units).
struct VitalLogoMark: View {
    enum Style {
        /// Teal C + forest V (light); mint C + ivory V (dark).
        case brand
        /// Ivory on teal / forest backgrounds.
        case reversed
        case mono(Color)
    }

    var size: CGFloat = 40
    var style: Style = .brand

    var body: some View {
        Canvas { ctx, canvasSize in
            let s = canvasSize.width / 100
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -1.5, y: 2.5)

            let (cColor, vColor) = colors
            let width: CGFloat = 11
            let knockout: CGFloat = 17.4
            let round = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)

            let c = Path { p in
                p.addArc(center: CGPoint(x: 50, y: 50), radius: 31, startAngle: .degrees(45), endAngle: .degrees(335), clockwise: false)
            }
            let v = Path { p in
                p.move(to: CGPoint(x: 28, y: 20))
                p.addLine(to: CGPoint(x: 52, y: 80))
                p.addLine(to: CGPoint(x: 84, y: 14))
            }
            let under = Path { p in
                p.addArc(center: CGPoint(x: 50, y: 50), radius: 31, startAngle: .degrees(308), endAngle: .degrees(335), clockwise: false)
            }

            // 1. The C.
            ctx.stroke(c, with: .color(cColor), style: round)
            // 2. Gap where the V crosses over the C (top left).
            var over = ctx
            over.clip(to: Path(CGRect(x: 0, y: 0, width: 44, height: 42)))
            over.blendMode = .clear
            over.stroke(v, with: .color(.black), style: StrokeStyle(lineWidth: knockout, lineJoin: .round))
            // 3. The V.
            ctx.stroke(v, with: .color(vColor), style: round)
            // 4. The C passes over the V's right arm.
            var gap = ctx
            gap.blendMode = .clear
            gap.stroke(under, with: .color(.black), style: StrokeStyle(lineWidth: knockout))
            ctx.stroke(under, with: .color(cColor), style: round)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var colors: (Color, Color) {
        switch style {
        case .brand: (VitalColors.accent, VitalColors.textPrimary)
        case .reversed: (VitalColors.warmIvory, VitalColors.warmIvory)
        case .mono(let c): (c, c)
        }
    }
}

/// "VitalCoach / HEALTH" lockup. The parent-company line is only for onboarding footers,
/// About, legal pages and the optional splash (see docs/design/BRAND.md).
struct VitalBrandLockup: View {
    enum Layout { case horizontal, stacked }

    var layout: Layout = .horizontal
    var markSize: CGFloat = 44
    var showsParentAttribution = false

    var body: some View {
        VStack(spacing: VitalSpacing.xs) {
            Group {
                if layout == .horizontal {
                    HStack(spacing: VitalSpacing.s) { VitalLogoMark(size: markSize); wordmark(alignment: .leading) }
                } else {
                    VStack(spacing: VitalSpacing.s) { VitalLogoMark(size: markSize * 1.6); wordmark(alignment: .center) }
                }
            }
            if showsParentAttribution {
                Text("A PrecisionPeptidePens company")
                    .vitalFont(.caption)
                    .foregroundStyle(VitalColors.textSecondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsParentAttribution ? "VitalCoach Health, a PrecisionPeptidePens company" : "VitalCoach Health")
    }

    private func wordmark(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            Text("VitalCoach")
                .font(.system(size: markSize * 0.52, weight: .bold))
                .foregroundStyle(VitalColors.textPrimary)
            Text("HEALTH")
                .font(.system(size: markSize * 0.24, weight: .semibold))
                .tracking(markSize * 0.08)
                .foregroundStyle(VitalColors.accent)
        }
    }
}

#Preview("Brand") {
    VStack(spacing: VitalSpacing.l) {
        VitalBrandLockup()
        VitalBrandLockup(layout: .stacked, showsParentAttribution: true)
        HStack(spacing: VitalSpacing.m) {
            VitalLogoMark(size: 64)
            VitalLogoMark(size: 64, style: .reversed)
                .padding(8).background(VitalColors.primaryTeal, in: RoundedRectangle(cornerRadius: 16))
        }
    }
    .padding()
    .vitalScreenBackground()
}
