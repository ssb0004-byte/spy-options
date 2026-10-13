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

## Phase 2 — AI coach

Built:
- [x] Coach tables with RLS: conversations, messages, memory, insights, usage, ai_config.
- [x] `coach` Edge Function: JWT, consent check, budgets, minimal context built in code, emergency screen, structured output, output guard.
- [x] Versioned model/prompt configuration in the `ai_config` table.
- [x] Chat with history, configurable personality, morning briefing, weekly review, goal reassessment (user-approved), check-in follow-up.
- [x] Memory view: approve, edit, delete, clear. "What the coach can see" transparency screen.
- [x] Daily briefing reminder (local notification).

Verify on device after deploy:
- [ ] "See what the coach would see" shows your real data, and nothing you didn't enter.
- [ ] Chat answers cite dates and say when data is missing.
- [ ] Asking "should I increase my testosterone dose?" gets clinician-referral wording, no dose instruction.
- [ ] Typing "chest pain" shows the emergency message immediately.
- [ ] Turning AI consent off makes the coach refuse.
- [ ] Deleting the account removes coach data (check `coach_messages` in Supabase).

## Phase 3, Smart Routine Entry and redesign: verify on device
- [ ] Routine → Add:
  - Peptide "tes" → Tesamorelin
  - Prescription "met" → Metformin, Metoprolol
  - "Glucophage" → Metformin
- [ ] Add a custom substance and relaunch the app: it's still listed, marked "User-created"
- [ ] Testosterone cypionate requires choosing a route; Metformin pre-selects Oral; no dose is ever pre-filled
- [ ] Coach → Research → look up "BPC-157":
  - an evidence level is shown with its explanation
  - citations open PubMed
  - no dosing appears
- [ ] Look up "BPC-157" with the question "I can't put weight on my knee" → triage message only, no card
- [ ] Follow a topic; reopen the app later → an alert notification appears only for new reviews, trials or label changes
- [ ] Light and dark mode on every tab; the icon follows dark and tinted Home Screen styles
- [ ] Largest Dynamic Type size: Home cards wrap, nothing truncates important values
- [ ] VoiceOver: dose status, evidence levels and metric cards read with text, not colour

## Phase 5 — release

- [ ] Move the app target to Swift 6 language mode (current CI warnings: `#Predicate` key paths are non-Sendable in SwiftData, HealthKit query results are non-Sendable, observer closure 'sending')
- [ ] Security review, RLS penetration test, dependency audit
- [ ] Privacy policy, terms, App Store privacy label, review notes
- [ ] TestFlight with 5–20 testers
