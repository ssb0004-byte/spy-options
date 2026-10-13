# VitalCoach Health design system (v1, awaiting founder approval)

Review page: `docs/design/review.html` (open in any browser). Code: `App/DesignSystem/`.

| Folder | Contents |
|---|---|
| `Theme/` | `VitalColors` (light/dark tokens), `VitalTypography` (`.vitalFont(_:)`, Dynamic Type via `@ScaledMetric`), `VitalTheme` (spacing, radii, shadows, motion, 44 pt minimum) |
| `Components/` | `VitalCard`, `VitalMetricCard` + `VitalSparkline`, `VitalButton`/`VitalButtonStyle`, `VitalTextField`, `VitalSectionHeader`, `VitalStatusIndicator`, `VitalInsightCard`, `VitalSubstanceRow`, `VitalEmptyState`, `VitalLoadingState`, `VitalChartContainer`, `VitalProgressIndicator` |
| `Brand/` | `VitalLogoMark` (Concept A, drawn in code), `VitalBrandLockup` |
| `Previews/` | `DashboardPreview` (light, dark, accessibility text size) |

## Contrast (measured, WCAG 2.1)
- Primary text: 11.6:1 light, 13.6:1 dark on cards. Secondary text: 6.0:1 and 8.2:1.
- **Brand teal #328577 with white text is 4.4:1**, below AA's 4.5:1 for normal-size text. Primary-button fills and small accent text therefore use `accentStrong` #2B7366 (5.6:1). #328577 stays the brand accent for icons, charts, large text and the logo. *Pending founder approval.*
- Semantic success/caution/critical/info: all ≥5.3:1 light and ≥6.4:1 dark, and always shown with an icon or text.
- Chart palette: six colors, each ≥3:1 against cards in both modes; legends pair a shape with a label.
- `borderControl` (text-field outline) is ≥3:1 (WCAG 1.4.11). `border` is decorative only.

## Rules
- Use tokens only: no literal colors or system teal in feature code.
- Motion uses `VitalMotion` and switches off with Reduce Motion.
- Touch targets are at least 44 pt.
- Preserve existing accessibility identifiers when migrating screens.

## Roll-out after approval
Migrate one screen per commit, each verified by CI:
1. Home
2. Routine
3. Trends
4. Coach
5. Check-in
6. Settings
7. Onboarding / sign-in

Remove the old `DesignSystem.swift` helpers once nothing uses them. Install the icon set from `docs/design/icons/` into `AppIcon.appiconset` (default, dark and tinted appearances).
