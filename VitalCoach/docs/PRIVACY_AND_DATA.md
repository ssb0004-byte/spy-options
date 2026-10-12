# Privacy, data handling and account deletion

This describes what the Phase 1 code does. It is not a legal privacy policy; one must be drafted and reviewed before public release.

## What is stored where

| Data | On iPhone | In Supabase (only with Cloud backup consent) |
|---|---|---|
| Profile, goals, preferences, consents | SwiftData store (file-protected, excluded from backup) | Yes, RLS-isolated per user |
| Measurements (manual + imported from Apple Health) | Yes | Yes |
| Substances, regimens, dose logs, side effects, check-ins, pain | Yes | Yes |
| Audit events (non-sensitive summaries such as "active → paused") | Yes | Yes |
| Session tokens | Keychain (`AfterFirstUnlockThisDeviceOnly`) | n/a |
| HealthKit query anchors, onboarding progress, "data received" flags | UserDefaults (no health values) | No |
| Progress photos, AI conversations, lab results | Not implemented in Phase 1 | — |

- **No analytics, crash-reporting, advertising or tracking SDKs** are included. The app makes network calls only to the configured Supabase project.
- **Consent is separate per purpose and recorded in an append-only ledger:** terms + 18+ attestation, cloud sync, AI processing (Phase 2), and photo storage (later).
- **Without cloud-sync consent, nothing is uploaded.** Changes still queue locally and upload only after consent is granted.
- **HealthKit:** read-only, requested per category. HealthKit data is never used for advertising or sold, in line with App Store Review Guideline 5.1.3.
- **Logging:** server errors are reported to the user using only the HTTP status and Postgres error code. Response bodies, which may echo health data, are never logged. The Edge Function logs only a status code.

## Encryption

- **In transit:** HTTPS only. The configuration loader rejects non-`https` URLs.
- **At rest on the device:** iOS Data Protection (`completeUntilFirstUserAuthentication`), plus Keychain storage for tokens.
- **At rest on the server:** Supabase encrypts databases and backups at rest. Verify the current guarantees in Supabase's security documentation for your plan and region.

## Export

Profile → Export my data produces a JSON file with every record the account has stored on this device. The format is documented by the table and column names in the migration. The file is written with complete file protection and shared via the iOS share sheet.

## Account deletion — what happens

1. The app calls the `delete-account` Edge Function with the user's JWT.
2. The function verifies the token, removes any objects under the user's prefix in the `progress-photos` bucket (empty in Phase 1), and deletes the auth user with the service role.
3. Postgres `ON DELETE CASCADE` removes **every** row in every user table, including the append-only tables. This is verified by `supabase/tests/10_rls_and_behaviour_test.sql`.
4. The app then wipes all local records for that user, HealthKit anchors and onboarding state, removes pending notifications, and clears the Keychain session.
5. If the server call fails, **nothing** is deleted locally and the user is told to retry.

**Retention limitations to disclose:**
- Supabase point-in-time recovery and daily backups can retain deleted data until those backups expire. Check your plan's backup retention; it is several days on paid plans.
- Data in Apple Health is untouched, because it belongs to the user's Health app.
- Exports the user saved elsewhere are outside the app's control.
- In Phase 2: whatever the AI provider retains under its API data policy. Document this, and prefer zero-data-retention options if eligible.

## Not yet done (required before public release)

- A professionally drafted privacy policy and terms of use. Review applicable law, including US state consumer-health-data laws (e.g. Washington My Health My Data Act), GDPR/UK GDPR if offered in Europe, and the FTC Health Breach Notification Rule.
- A data-retention schedule, and a breach response plan.
- App Store privacy "nutrition label" answers. They must match `App/Resources/PrivacyInfo.xcprivacy`.
- Independent security review and penetration test.
- **Do not claim HIPAA compliance.** No assessment or Business Associate Agreement exists.
