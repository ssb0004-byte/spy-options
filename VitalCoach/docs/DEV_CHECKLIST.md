# Development checklist

## Phase 1 — verify on a real iPhone (manual; can't be automated in CI)

- [ ] Sign in with Apple succeeds; killing and relaunching the app keeps you signed in
- [ ] Onboarding: skip optional steps → they're listed on the Profile tab; consent and goals can't be skipped
- [ ] Apple Health: connect weight + body fat → after an Arboleaf weigh-in, values appear (pull-to-refresh on Home)
- [ ] Delete a sample in the Health app → it disappears from Trends after refresh
- [ ] A category declined in the iOS sheet shows "Requested · no data yet", never "connected"
- [ ] Add a supplement at 08:00 and 20:00 → reminders fire; **Taken** from the lock screen logs the dose
- [ ] "Hide names on lock screen" hides the substance name
- [ ] Airplane mode: log doses and a check-in, then reconnect → Settings → Sync shows 0 waiting
- [ ] Change a dose → the history shows both regimens; earlier days still show the old dose
- [ ] Correct a "Taken" to "Skipped" → the history shows both entries
- [ ] Change the device time zone → today's times stay at the same wall-clock time
- [ ] Check-in note "chest pain" → emergency message appears
- [ ] Export → open the JSON file in Files
- [ ] Delete account → the user and rows are gone in Supabase; the app returns to sign-in
- [ ] VoiceOver walkthrough of every tab; largest Dynamic Type size; dark mode

## Known limitations (Phase 1)

- The app layer has not been run on a device by the author. CI compiles and runs the app tests on the iOS Simulator; device behaviour (HealthKit, notifications, Sign in with Apple) still needs the manual checks above.
- Pausing a substance doesn't record pause dates in the regimen. Its 14-day history may show paused days as "Not logged". Planned for Phase 4 analytics.
- The urgent-symptom phrase list is not clinically validated (see RELEASE_READINESS.md).
- Local queries load a user's records into memory. This is fine for personal-scale data; add indexed SwiftData queries if any table exceeds roughly 50k rows.
- A `delete-account` Edge Function failure leaves the account intact (by design), but the function itself has not been executed in CI.

## Phase 2 — AI coach (start only after the Phase 1 checks pass)

- [ ] `ai_usage`, `coach_conversations`, `coach_messages`, `coach_memory`, `generated_insights` tables with RLS
- [ ] Edge Function `coach-chat`: verify JWT → check AI consent → check budgets → build minimal context server-side → OpenAI (structured outputs for safety classification) → store
- [ ] Versioned prompt and model configuration table
- [ ] Memory inspector (view / correct / clear)
- [ ] Morning briefing and weekly summary from deterministic VitalCore metrics, with AI used only for wording

## Phase 5 — release

- [ ] Move the app target to Swift 6 language mode (current CI warnings: `#Predicate` key paths are non-Sendable in SwiftData, HealthKit query results are non-Sendable, observer closure 'sending')
- [ ] Security review, RLS penetration test, dependency audit
- [ ] Privacy policy, terms, App Store privacy label, review notes
- [ ] TestFlight with 5–20 testers
