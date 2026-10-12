# Phase 1 acceptance criteria and status

Legend:
- ✅ implemented and verified by automated tests
- 🟡 implemented; needs on-device or Mac verification (see checklist)
- ⬜ not implemented / deferred

| # | Criterion | Status | Evidence |
|---|---|---|---|
| 1 | Complete Xcode project opens and builds for iOS 18 | ✅ | CI `ios-app` job (Xcode 16.4, iOS Simulator): build succeeded; 4 SwiftData app tests + 86 VitalCore tests passed. Remaining warnings are Swift 6-mode concurrency diagnostics only (see ARCHITECTURE.md). |
| 2 | Tab navigation: Home, Trends, Routine, Coach, Profile | 🟡 | `App/VitalCoachApp.swift` |
| 3 | Sign in with Apple → Supabase session; tokens in Keychain; refresh; sign-out | ✅ protocol / 🟡 UI | `SupabaseTests` (request shape, raw-nonce flow, refresh de-duplication, failed refresh signs out) |
| 4 | Device-only mode when the backend isn't configured, clearly labelled | 🟡 | `SignInView`, Home banner |
| 5 | Individual profile; records isolated per user | ✅ | `RepositoryTests`, RLS tests (26 checks), `otherUsersRowsAreNeverPulled` |
| 6 | Adaptive onboarding; only consent + goals required; skips resurface later | ✅ logic / 🟡 UI | `onboardingRequiresConsentAndGoalsButSkipsOptional` |
| 7 | Goal selection and revision without ranking | ✅ / 🟡 | `UserGoal.priority` optional; Goals editor |
| 8 | Consent management (append-only, versioned, per purpose) | ✅ | `consentLatestRecordWinsAndVersionMatters`, `consent_records` append-only trigger |
| 9 | HealthKit authorization per category; honest status; anchored import with deletions; dedupe; daily stats for high-frequency data; background delivery | ✅ merge logic / 🟡 HealthKit calls | `HealthImportTests`; `HealthKitService` |
| 10 | Manual measurement entry with validation, unit conversion, provenance and quality | ✅ | `MeasurementTests` |
| 11 | Body-composition dashboard and charts; estimate/self-reported/derived distinguished; gaps not filled | ✅ calculations / 🟡 charts | `TrendTests`; `TrendsView` |
| 12 | Medication/supplement manual entry with categories, routes, fractional doses, units | ✅ / 🟡 | `UnitsTests`, `AddSubstanceView` |
| 13 | Versioned regimens: changes preserve history | ✅ | `revisionPreservesHistory`, `currentRegimenFollowsRevisions` |
| 14 | Schedules: daily / every N days / weekdays / as-needed / cycles; DST and travel | ✅ | `ScheduleTests` (11 tests incl. spring-forward and fall-back) |
| 15 | Planned vs actual records; one-tap log; skip / missed / late / corrected / voided; never presumed taken | ✅ | `DoseLogTests`, DB append-only test |
| 16 | Reminders with Taken/Skip actions, discreet by default, re-planned idempotently, within the 64-notification limit | ✅ planning / 🟡 delivery | `reminderPlanningIsIdempotentCappedAndDiscreet` |
| 17 | Daily/weekly adaptive check-ins with pain location, 0–10 severity, stiffness, functional impact | ✅ / 🟡 | `AdaptiveTests`, `painValidation` |
| 18 | Urgent-symptom message on concerning check-in text | ✅ (unvalidated phrase list) | `urgentSymptomScreen` |
| 19 | Offline persistence; queued sync; idempotent retry; conflict resolution that never silently discards; backoff | ✅ | `SyncEngineTests` (11 tests) |
| 20 | Supabase schema with RLS on every table, optimistic concurrency, append-only tables, cascade deletion | ✅ | `supabase/tests/run.sh` against Postgres 16 |
| 21 | The app's JSON payloads match the database schema in both directions | ✅ | `SchemaFixtureTests` + `ServerRowDecodingTests` via `run.sh` |
| 22 | Editable settings: profile, goals, units, coach style, notifications, HealthKit, consents, sync status | 🟡 | `SettingsView` |
| 23 | Data export (portable JSON) | ✅ / 🟡 | `exportIsValidJSONWithAllTables` |
| 24 | Account deletion (server + local) | ✅ cascade / 🟡 Edge Function | DB cascade tests; Edge Function not executed (no Deno runtime here) |
| 25 | Accessible empty/loading/error states; Dynamic Type; VoiceOver labels; light/dark | 🟡 | System fonts and colors throughout; `ScaleRating` adjustable action |
| — | Database search, label photo extraction, conversational intake | ⬜ | Phase 2–3 (requires AI backend and a licensed catalog) |
| — | Progress photos, lab results | ⬜ | Later phases (private storage bucket, lab schema) |
| — | AI coach | ⬜ | Phase 2; the placeholder tab makes no AI claims |
