# Cost estimates

Prices change often. The figures below are planning estimates as of this writing; confirm them on each vendor's pricing page before relying on them. Excluded: Apple Developer Program ($99/year), hardware, and engineering time.

## Phase 1 (this build): development and private testing — **about $0/month**

| Item | Service | Expected cost |
|---|---|---|
| Database + auth + Edge Functions | Supabase **Free** plan (small database, generous monthly-active-user and function quotas; projects pause after about a week of inactivity) | $0 |
| Push / reminders | Local notifications (on-device) | $0 |
| HealthKit | Apple | $0 |
| CI | GitHub Actions: Linux jobs are cheap. **The macOS job uses macOS minutes**, which count 10× against a private repo's free allowance. Run it manually (`workflow_dispatch`) if minutes get tight. | $0 within free minutes |

## Phase 2–3 estimates (AI coach + research)

| Item | Approach | Rough monthly cost |
|---|---|---|
| Supabase | Stay on Free while testing; move to **Pro (about $25/month)** for no auto-pausing, daily backups and support before real users | $0–25 |
| OpenAI | Small/cheap model for chat and summaries; larger models only for rare deep analyses. Hard per-user daily token caps enforced server-side. | Example: 10 testers × 30 messages/day × ~3k tokens ≈ 27M tokens/month. On a low-cost model this is typically a few dollars; check current per-token prices. |
| Research APIs | PubMed E-utilities, ClinicalTrials.gov, openFDA: free; register a free NCBI API key. Fetch on a schedule and cache. | $0 |

**Target: under $25/month for development and limited private testing is realistic.**

## Growth

| Active users | Likely setup | Order of magnitude |
|---|---|---|
| ≤ 50 testers | Supabase Free/Pro + capped AI | $0–40/month |
| ~1,000 | Supabase Pro + compute add-on; AI is the main variable cost | $50–300/month, depending on AI usage per user |
| 10,000+ | Larger database instance, paid monitoring, possibly a BAA-capable vendor tier if regulation requires it | Hundreds to thousands per month; plan for subscription revenue |

AI cost scales with messages per user, so the per-user budget cap is the key control. A public audience cannot be served for $25/month.

## Safeguards against surprise bills (implemented or planned)

- **Phase 1:** there are no paid APIs. The Supabase free plan cannot bill.
- **Phase 2 (planned design):**
  - OpenAI keys exist only in Supabase Edge Function secrets.
  - Each request checks a per-user daily token budget and a global monthly budget stored in Postgres, and refuses with a friendly message when exceeded.
  - Hard limits are also set in the OpenAI dashboard.
- Keep Supabase **Spend Cap** enabled after upgrading.
