# VitalCoach architecture

## Overview

```mermaid
flowchart LR
  subgraph iPhone
    UI[SwiftUI views<br/>Home · Trends · Routine · Coach · Profile]
    AM[AppModel<br/>@MainActor @Observable]
    subgraph VitalCore [VitalCore Swift package — platform-independent, unit-tested]
      DOM[Domain: units, metrics, trends,<br/>regimens, schedules, dose log,<br/>check-ins, consent, onboarding]
      REPO[Repository<br/>local-first writes + outbox]
      SYNC[SyncEngine<br/>push/pull, conflicts, backoff]
      SB[Supabase REST client<br/>Auth + PostgREST]
    end
    SD[(SwiftData store<br/>file-protected)]
    KC[(Keychain<br/>session tokens)]
    HK[HealthKitService<br/>anchored + observer queries]
    NS[NotificationService<br/>dose & check-in reminders]
  end
  AH[(Apple Health)]
  ARB[Arboleaf app] -->|writes weight, body fat %, BMI, lean mass| AH
  AH -->|read-only| HK
  UI --> AM --> REPO --> SD
  AM --> HK --> REPO
  AM --> NS
  SYNC --> REPO
  SYNC --> SB
  SB --> KC
  subgraph Supabase [Supabase project]
    GT[Auth / GoTrue<br/>Sign in with Apple]
    PR[PostgREST]
    PG[(Postgres<br/>RLS on every table)]
    EF[Edge Function<br/>delete-account]
  end
  SB -->|HTTPS + user JWT| GT
  SB -->|HTTPS + user JWT| PR --> PG
  AM -->|HTTPS + user JWT| EF --> GT
  EF -.->|cascade delete| PG
  subgraph Later phases
    AI[Edge Functions → OpenAI<br/>Phase 2]
    RS[Research adapters<br/>PubMed, ClinicalTrials.gov, openFDA<br/>Phase 3]
  end
```

## Layers

| Layer | Where | Responsibilities | Tested by |
|---|---|---|---|
| Domain + application logic | `Packages/VitalCore` | All calculations, validation, scheduling, sync, REST protocol | 86 Swift tests (Linux and macOS) |
| Persistence adapter | `App/Services/Persistence.swift` | SwiftData implementation of `RecordStore`, Keychain session storage | `AppTests/` (macOS/iOS only) |
| Platform services | `App/Services/*` | HealthKit, notifications | Manual device testing (see checklist) |
| Presentation | `App/AppModel.swift`, `App/Features/*` | SwiftUI views; `AppModel` exposes state and intents | Manual + CI build |
| Backend | `supabase/` | Schema, RLS, triggers, Edge Functions | `supabase/tests/run.sh` (real Postgres) |

**Presentation pattern.** This is MVVM-style. `AppModel` is the shared view model (session, loaded data, intents). Each feature view keeps only form state. Every rule a test can check (for example "a dose without a record is never counted as taken") lives in VitalCore.

**Dependency injection.** VitalCore depends only on protocols: `RecordStore`, `RemoteStore`, `HTTPTransport`, `SessionStorage`, `TimeSource`. Tests inject in-memory fakes; the app injects SwiftData, URLSession, and the Keychain.

## Key decisions

1. **Local-first.** Every write goes to the on-device store first, together with an outbox entry, in one transaction. The app works fully offline for history, routines, dose logging and check-ins. Sync never drops an entry: failures retry with exponential backoff, and permanently rejected items stay visible in Settings → Sync.
2. **Planned and actual doses are separate.**
   - *Planned* doses are derived deterministically from **versioned regimens**. A regimen is never edited in place: a dose or schedule change ends the old regimen and starts a new one with `supersedes_id`, so history can't be rewritten.
   - Each planned slot has an `occurrenceKey` of the form `regimen|local date|local time`. It is independent of time zone, so travel doesn't break the link between a planned slot and its logged dose.
   - *Actual* administrations are **append-only**. A correction is a new row that supersedes the old one, and an "undo" is a `voided` row. The full chain is shown in the UI and kept on the server.
   - A slot with no record is shown as "Not logged", never as taken.
3. **DST and time zones.**
   - By default, schedules follow the device time zone (8:00 stays 8:00 when you travel). They can optionally be pinned to one zone.
   - A time that doesn't exist on a spring-forward day (e.g. 02:30) moves forward and is flagged. A time that occurs twice on a fall-back day is scheduled once, at its first occurrence.
   - This is implemented with explicit UTC-offset arithmetic, so it behaves the same on every platform. Tests cover America/New_York transitions.
4. **Optimistic concurrency.**
   - Mutable rows carry a `version`. A server trigger accepts an update only when it carries `OLD.version + 1`; otherwise it raises `PT409`, which PostgREST returns as HTTP 409.
   - On a conflict, the edit with the later client timestamp wins, and the losing version is kept in a local conflict log, so nothing is silently discarded.
   - Uploads are idempotent: rows use client-generated UUIDs with `on_conflict=id`. HealthKit imports use deterministic IDs, so two devices importing the same sample converge on a single row.
5. **Incremental pull.** Pulls use keyset pagination on `(server_updated_at, id)`. Each sync first re-reads a 2-minute overlap window to tolerate timestamp ordering across concurrent server transactions.
6. **HealthKit.**
   - Read-only, requested per category in context.
   - Body measurements are imported with anchored queries, which return additions and deletions.
   - Heart rate, steps and active energy are imported as daily statistics, which HealthKit de-duplicates across iPhone and Watch. This keeps storage bounded.
   - Because iOS hides read-authorization status, the UI says "Requested · no data yet" until data actually arrives.
   - Background delivery uses observer queries. iOS controls the timing, and pull-to-refresh is always available.
7. **Body-composition honesty.**
   - Lean body mass, fat-free mass, skeletal muscle mass, and the scale's proprietary "muscle mass" are distinct metric kinds.
   - Scale BIA values are labelled *Estimate*; manual entries *Self-reported*; app-calculated values *Calculated*.
   - Apple Health has no skeletal-muscle type, so that metric is manual-only, and no Arboleaf API integration is claimed.
8. **Units.**
   - Values are stored in canonical units (kg, cm, %, bpm, ms) and converted only for display.
   - Doses use `Decimal`, so 0.1 mg stays exactly 0.1. Only mcg/mg/g are converted automatically. mL→mass requires a concentration the user confirms, and IU and "units" are never converted.
9. **Timestamps.** Timestamps are serialized at exactly millisecond precision, using rounding rather than truncation. A test caught a bug where truncation lost 1 ms on every round trip.
10. **Security.**
    - The client holds only the public anon key; every request carries the user's JWT, and Row Level Security decides access.
    - No client hard-deletes. Account deletion runs through an Edge Function using the service role, which never leaves the server, and cascades through all rows.
    - Tokens are stored in the Keychain with `AfterFirstUnlockThisDeviceOnly`.
    - The local store uses `completeUntilFirstUserAuthentication` file protection and is excluded from backups. Error messages never echo server response bodies, which could contain health data.

## Swift 6 compatibility

- **VitalCore** builds in **Swift 6 language mode** with complete strict-concurrency checking (verified with Swift 6.1.3).
- **The app target** builds in **Swift 5 language mode with `SWIFT_STRICT_CONCURRENCY = complete`**. HealthKit, UserNotifications and SwiftData callbacks still carry pre-concurrency annotations that can turn into errors in Swift 6 mode, and the app layer couldn't be compiled in the environment it was written in. Diagnostics still appear as warnings. Moving the app target to Swift 6 mode is a Phase 5 checklist item once those warnings are resolved on a Mac.

## Database tables (Phase 1)

`user_profiles`, `user_goals`, `user_preferences` (includes notification preferences), `consent_records` (append-only ledger), `health_measurements` (provenance inline: source kind/name/bundle id/external id/quality), `symptom_entries`, `pain_entries`, `user_substances`, `substance_regimens` (versioned), `actual_administrations` (append-only), `adverse_effect_reports`, `audit_events` (append-only).

Not created yet, on purpose:
- `scheduled_administrations`: planned doses are derived from regimens.
- `sync_state`: kept on the device only.
- `measurement_sources`: provenance is stored inline for now.
- `lab_results`, `progress_photos` (with a private storage bucket), `coach_*`, `generated_insights`, `research_sources`, `study_references`, `safety_alerts`, `substance_catalog`: added in the phase that needs them.
