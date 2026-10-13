# Phase 3: Proactive Compound Intelligence (research)

This phase adds evidence-graded **Compound Insight Cards**, **proactive discovery** of interventions (drug and non-drug), and **followed research interests** with update alerts. It is built as a new Supabase Edge Function, `research`, next to the existing `coach`.

> Educational only. Nothing here diagnoses, prescribes or gives dosing. The red-flag screen is conservative and **not clinically validated** (see RELEASE_READINESS.md).

## Architecture

```
iPhone (VitalCore ResearchClient)
   │  POST /functions/v1/research  {op: insight_card | discover | interests_list | interests_add | interests_remove | check_updates}
   ▼
research Edge Function (supabase/functions/research)
   index.ts         Deno entry: auth.getUser (401 without a valid token), supabase-js adapters
   lib/handler.ts   pipeline per op (pure, injected db/fetch/cache/model)
   lib/sources.ts   PubMed E-utilities, ClinicalTrials.gov API v2, openFDA label — URL builders, parsers, shared cache
   lib/evidence.ts  7 evidence levels, per-study classification, deterministic evidence CAP, citation verification
   lib/interactions.ts  FDA-label text + curated class rules + "no data" cross-check vs current compounds/conditions/allergies
   lib/candidates.ts    curated discovery candidates (≥ half non-drug) and established first-line approaches
   lib/updates.ts       "meaningful update" filter for alerts
   lib/prompt.ts        instructions + strict JSON schemas (OpenAI Responses API, store:false)
   reuses ../coach/lib: context.ts (user summary), budget.ts, openai.ts (callModel), safety.ts (red flags, dosing stripper)
   reuses ../coach/shared_db.ts: consent check + RLS-scoped row loading (also used by coach/index.ts)
```

### Pipelines

**`insight_card {compound, question?, force_refresh?}`**
1. Validate/sanitize the compound term.
2. **AI consent** (server-side, from the consent ledger) → 403 `consent_required` otherwise.
3. **Red-flag triage** on the user's question (`screenRedFlags` in `coach/lib/safety.ts`): emergencies (chest pain, stroke signs, major trauma, saddle numbness/incontinence…) and urgent musculoskeletal flags (can't bear weight, hot swollen joint/fever, pop + rapid swelling, locking/giving way after injury, numbness/weakness, swollen calf, severe pain). `urgent`/`emergency` → return `{triage, card: null, stopped: true}` — no research lookups, no model call. `see_clinician` (e.g. giving way without injury, night pain) → card is produced with the triage notice attached.
4. Per-user card cache (`compound_insights`, 7 days, keyed by compound + a hash of question/routine/conditions/goals).
5. Budget check (same `ai_config` limits and `ai_usage` accounting as the coach).
6. Retrieval for the compound term (and openFDA labels for up to 5 of the user's Rx/OTC/hormone compounds, for the interaction check).
7. Deterministic: interaction flags, regulatory status (from openFDA), established approaches for the complaint (e.g. knee → exercise therapy/PT, weight management, load management, OTC analgesics per label, clinician evaluation).
8. Model (strict JSON schema) → **guards**: citation IDs verified against the retrieved set (others dropped and listed in `dropped_citation_ids`), evidence levels **capped**, dosing sentences removed, absolute safety claims ("completely safe", "no interactions") removed, anecdotes wrapped in a fixed "unverified" block with bias explanations.
9. Persist card; record usage.

**`discover {concern?, max?}`** — red-flag triage on the optional concern text **and** structured data (pain ≥ 8/10 in 14 days or an unresolved severe side effect → `see_clinician` notice) → candidates from complaints (pain log, profile injuries, concern text), goals and followed interests (≥ half non-drug) → retrieval per candidate → one model call to explain relevance, claim levels and cite → same guards per suggestion (citations must come from *that candidate's* retrieved set) → non-drug options are re-added deterministically if the model omitted them. Cached per user per day.

**`interests_list / interests_add {term, kind?, display_name?} / interests_remove {id}`** — follows up to 25 compounds/topics. Adding requires AI consent; listing and removing do not.

**`check_updates {force_refresh?}`** — no AI call. For each interest not checked in the last 12 h (max 10 per call): retrieve (24 h source cache), compare to the stored `last_seen` snapshot, create `research_alerts` only for meaningful events, update the snapshot. The first check records a baseline (no alerts). The app polls this and posts **local notifications** (`ResearchAlertNotifier.toNotify`); no push server is needed.

### Coach integration

The coach chat stays general. Its instructions now say: for questions about a specific compound, answer briefly and list the names in a new `research_topics` output field (exposed as `CoachMetadata.researchTopics` in Swift). The app shows an "Open Research card" action for each, which calls `ResearchClient.insightCard`. The coach also runs the same red-flag triage: urgent flags short-circuit chat with triage advice (no model call); `see_clinician` flags prepend a notice. Its dose guard is stricter for peptide/investigational/compounded topics: sentences with doses, frequencies or cycles are **removed**, not just annotated.

## Evidence rules (deterministic; `lib/evidence.ts`)

| Level | Cap rule: allowed only if the *verified, cited* sources include… |
|---|---|
| `established_human` | ≥1 human meta-analysis/systematic review, **or** ≥2 human RCTs, **or** an FDA label with an NDA/ANDA/BLA number (labeled uses only) |
| `moderate_human` | 1 human RCT, or a clinical practice guideline |
| `preliminary_human` | non-randomized clinical trial, observational study, case report/series, or a ClinicalTrials.gov interventional trial with posted results |
| `preclinical_animal` | an animal study |
| `in_vitro_mechanistic` | a cell/lab study |
| `anecdotal_community` | nothing — never backed by citations; always labeled unverified |
| `insufficient` | default when nothing above applies (narrative reviews and trial registrations alone support nothing) |

Study classification per PubMed record uses the esummary `pubtype` array, a MeSH-filtered `animals[mh] NOT humans[mh]` search to tag animal-only records, and title keywords (rats/mice/rodent/porcine…, in vitro/cell line/fibroblasts…). **Animal/lab signals win over design pubtypes**, so a "systematic review of rodent studies" counts as animal evidence. If the model claims a higher level than supported, the server lowers it and records `capped: true` with a plain-language `cap_reason`. Each studied application is capped by its own citations. There is no single numeric score anywhere.

**Anecdotal block** (always): `verified: false`, label "Unverified anecdotal reports — not evidence of effectiveness or safety", and fixed explanations of placebo, selection/reporting, survivorship, product contamination/purity, conflicts of interest, and natural recovery/co-interventions.

**Dosing**: never provided for any compound, including doses used in studies. `stripDosing` removes any sentence with an amount + unit (mg, mcg, IU, mL, mg/kg…), explicit protocol words (dosage, dosing schedule, per kg), or a frequency/cycle term (daily, twice a week, 4 weeks on, cycle, stack, titrate…) combined with dose words (inject, dose, subcutaneous, vial…) or the compound's name. Every card carries `dosing_note` with clinician-referral wording.

**Regulatory status** comes only from openFDA: `approved_label` (application number present), `label_without_application`, `no_label_found` (with the caveat that absence is not proof), or `unknown` if openFDA couldn't be reached. WADA status is always `unknown` with a pointer to the WADA list / Global DRO (no WADA API is used; a curated list was deliberately not added).

**Interactions** (`lib/interactions.ts`): (1) FDA label sections (boxed warning, contraindications, drug interactions, warnings) of the researched compound are scanned for the user's compound names and drug-class terms, and the user's own Rx/OTC labels are scanned for the researched compound/class; (2) a small curated rule table (e.g. NSAIDs + ACE inhibitors/ARBs/diuretics; NSAIDs + anticoagulants/SSRIs; potassium + ACE inhibitors; vitamin D/calcium + thiazides; St John's wort; fish oil + anticoagulants; GLP-1 RAs + insulin/sulfonylureas) and condition rules (NSAIDs with kidney disease, ulcers, heart disease, hypertension; acetaminophen with liver disease); (3) a **"no data"** flag when the compound has no FDA label (e.g. BPC-157), naming the user's current compounds. It is not a complete interaction checker; every flag points to a pharmacist/clinician.

## Privacy

- External research APIs receive **only** the sanitized compound/topic term (`sanitizeTerm` rejects emails, URLs, UUIDs, long digit runs and body measurements) plus fixed parameters. Never user IDs, names, questions or health values. Lookups for the user's own Rx/OTC compounds send only the compound name (e.g. "lisinopril"), from the server, without identifiers. Verified by the test "outbound research URLs contain only compound/topic terms".
- The optional `NCBI_API_KEY` is the developer's key, never stored in cache keys.
- `research_cache` is shared and **service-only** (clients can't read or write it), contains only public API responses, 7-day TTL in the function; `prune_research_cache()` deletes entries older than 30 days.
- The AI model sees: compound, question, goals, complaints, pain summary, current compound names/categories, conditions, allergies, age, the retrieved citation list, and the deterministic flags. Requests use `store: false`. AI consent is required for all ops except listing/removing interests.
- Cards, discoveries, interests and alerts are RLS-scoped, written only by the function, readable/deletable by the owner, and cascade-deleted with the account (`supabase/tests/40_research_test.sql`).

## Cost

- Research APIs are free (PubMed E-utilities: 3 req/s without a key, 10 req/s with a free key; ClinicalTrials.gov and openFDA: free, rate-limited). One uncached compound lookup ≈ 4 PubMed + 1 ClinicalTrials.gov + 1 openFDA request; repeat lookups within 7 days hit the shared cache.
- AI: one model call per insight card (~3–6k input tokens, ≤ ~2.5k output) and one per discovery (~5–10k input). Both are cached (cards 7 days per user/context, discovery 1 day) and counted against the coach's existing per-user daily and global monthly budgets in `ai_config`.
- `check_updates` makes no AI calls.

## Setup

1. Apply the migration `20261014000001_phase3_research.sql` (the deploy workflow runs `supabase db push`).
2. Deploy the function: `supabase functions deploy research --no-verify-jwt` (included in `.github/workflows/vitalcoach-supabase-deploy.yml`, which also smoke-tests that it returns 401 without auth). `supabase/config.toml` sets `verify_jwt = false`; the function verifies tokens itself.
3. Secrets: `OPENAI_API_KEY` (already set for the coach). **Optional:** `NCBI_API_KEY` (free from your NCBI account → API Key Management) — set it in Supabase → Edge Functions → Secrets. Nothing else is required; no paid integrations.
4. The function imports from `../coach/lib/*` and `../coach/shared_db.ts`; the Supabase CLI bundles these relative imports.

## What is and isn't verified

Verified here (offline):
- `node --experimental-strip-types --no-warnings --test VitalCoach/supabase/functions/research/lib/research.test.ts` — evidence cap, classification, parsers, invented-citation dropping, anecdote labeling, dosing removal, red-flag stop, outbound-URL privacy, cache behaviour, interactions, meaningful-update filter, consent, budget, discovery with non-drug options, schema strictness, interests.
- Coach tests (incl. red-flag chat short-circuit and peptide dose stripping), DB/RLS tests (`supabase/tests/run.sh`), Swift `ResearchTests`, `deno check` of all functions.
- `demo/demo.ts` → `docs/research_demo_output.txt` (fictional user Alex Rivera, fixture API data, stubbed model).

**Not verified live** (this build environment cannot reach PubMed, ClinicalTrials.gov or openFDA): the fixtures follow the documented response shapes, but real responses should be spot-checked after deploy — in particular the ClinicalTrials.gov `fields`/`sort` parameters (the code retries without `fields` on HTTP 400), openFDA's `search` syntax for brand/generic/substance names, and PubMed `sort=pub_date`. The real OpenAI structured output for these schemas has not been exercised. The fixture studies are fictional and labeled `[FIXTURE]`.

## Known limitations

- Candidate interventions for discovery come from a small curated map (complaints/goals) plus followed interests; the model may suggest up to two extra topics, which have no evidence until the user opens a card for them.
- Relevance ranking is PubMed's; the evidence cap checks study *design*, not whether a study actually supports the specific claim. The model is instructed to cite only relevant studies, and citations are shown so users can check.
- Interaction checking is partial (label text + curated rules). WADA status is not checked.
- The red-flag screen is phrase-based (with simple negation handling) and not clinically validated.
