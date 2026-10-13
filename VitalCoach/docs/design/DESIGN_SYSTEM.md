# VitalCoach Health design system (v1, approved and applied)

Review page: `docs/design/review.html` (open in any browser). Code: `App/DesignSystem/`.

| Folder | Contents |
|---|---|
| `Theme/` | `VitalColors` (light/dark tokens), `VitalTypography` (`.vitalFont(_:)`, Dynamic Type via `@ScaledMetric`), `VitalTheme` (spacing, radii, shadows, motion, 44 pt minimum) |
| `Components/` | `VitalCard`, `VitalMetricCard` + `VitalSparkline`, `VitalButton`/`VitalButtonStyle`, `VitalTextField`, `VitalSectionHeader`, `VitalStatusIndicator`, `VitalInsightCard`, `VitalSubstanceRow`, `VitalEmptyState`, `VitalLoadingState`, `VitalChartContainer`, `VitalProgressIndicator` |
| `Brand/` | `VitalLogoMark` (Concept A, drawn in code), `VitalBrandLockup` |
| `Previews/` | `DashboardPreview` (light, dark, accessibility text size) |

## Contrast (measured, WCAG 2.1)
- Primary text: 11.6:1 light, 13.6:1 dark on cards. Secondary text: 6.0:1 and 8.2:1.
- **Brand teal #328577 with white text is 4.4:1**, below AA's 4.5:1 for normal-size text. Primary-button fills and small accent text therefore use `accentStrong` #2B7366 (5.6:1). #328577 stays the brand accent for icons, charts, large text and the logo. *Approved by the founder.*
- Semantic success/caution/critical/info: all ≥5.3:1 light and ≥6.4:1 dark, and always shown with an icon or text.
- Chart palette: six colors, each ≥3:1 against cards in both modes; legends pair a shape with a label.
- `borderControl` (text-field outline) is ≥3:1 (WCAG 1.4.11). `border` is decorative only.

## Rules
- Use tokens only: no literal colors or system teal in feature code.
- Motion uses `VitalMotion` and switches off with Reduce Motion.
- Touch targets are at least 44 pt.
- Preserve existing accessibility identifiers when migrating screens.

## Roll-out (done)
- **Founder approvals:**
  - Logo concept A
  - the recommended icon set
  - the deeper teal `#2B7366` for buttons and small text
- **Icon:** default, dark and tinted variants are in `AppIcon.appiconset`.
- **Shared components:** the original helpers in `DesignSystem.swift` (`Card`, `NoticeBanner`, `QualityBadge`, `MetricTile`, `ScaleRating`, `StatusPill`, `EmptyStateView`) keep their APIs but draw with the tokens. Every screen picked up the new look without behaviour changes.
- **Home:** rebuilt to match the approved dashboard.
- **Lists and forms:** use `.vitalListBackground()` and `.vitalRow()`.
- **Buttons:** system styles are replaced by `VitalButtonStyle`.
- **Brand:** the lockup is on sign-in and onboarding. Parent attribution appears only in the sign-in footer, the onboarding footer and Profile → About.
