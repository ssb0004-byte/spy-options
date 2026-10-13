# Phase 2 setup: turning on the AI coach

About 15 minutes, all in a web browser. You'll set up three things:

1. An **OpenAI API key**, stored only in Supabase.
2. **Two GitHub secrets**, so Claude can deploy database changes and server code for you.
3. A **spending limit** on OpenAI.

> Never paste keys or passwords into chat, code, or files. They go only into the Supabase or GitHub *Secrets* pages.

---

## Step 1 — Create an OpenAI API key

1. **Where:** https://platform.openai.com → sign in or sign up → **Settings → Billing**.
2. **Action:** add a payment method and buy a small amount of credit (e.g. $5–10). The API is prepaid.
3. **Then:** go to **Settings → Limits** (or *Usage limits*) and set a **monthly budget** you're comfortable with, e.g. $10. This is your hard safety net, on top of the app's own limits.
4. **Then:** go to **API keys → Create new secret key**.
   - Name: `vitalcoach-supabase`.
   - Permissions: All (or Restricted with *Responses: write*).
   - Copy the key. It starts with `sk-` and is shown only once.
5. **Verify:** the key appears in the API keys list.
6. **Next:** step 2.

## Step 2 — Put the key in Supabase (and only there)

1. **Where:** Supabase dashboard → your project → **Edge Functions → Secrets** → **Add new secret**.
2. **Values:**
   - Name: `OPENAI_API_KEY`
   - Value: the `sk-…` key from step 1.
3. Click **Save**, then delete the key from wherever you pasted it temporarily.
4. **Verify:** `OPENAI_API_KEY` appears in the secrets list. Its value stays hidden.
5. **Next:** step 3.

## Step 3 — Let GitHub deploy to Supabase for you

This lets Claude apply database migrations and deploy the `coach` function without you copy-pasting files.

**3a. Supabase access token**
1. **Where:** https://supabase.com/dashboard/account/tokens → **Generate new token**.
2. Name it `github-vitalcoach`, then copy the token (starts with `sbp_`).

**3b. Database password**
- This is the password you chose when you created the project.
- If you've lost it: Supabase → **Project Settings → Database → Reset database password**. Resetting doesn't affect the app, which never uses this password.

**3c. Add both to GitHub**
1. **Where:** GitHub repo → **Settings → Secrets and variables → Actions → Secrets** tab → **New repository secret**.
2. Add these two:

   | Name | Value |
   |---|---|
   | `SUPABASE_ACCESS_TOKEN` | the `sbp_…` token |
   | `SUPABASE_DB_PASSWORD` | your database password |

3. **Verify:** both names appear under *Repository secrets*.
4. **Next:** tell Claude **"coach secrets are in, deploy it"**. Claude will:
   - deploy the database tables and the `coach` function,
   - check the OpenAI key is present,
   - start a new TestFlight build.

## Step 4 — Use it

1. Update VitalCoach from TestFlight.
2. In the **Coach** tab, tap **See what the coach would see**. This shows the exact summary of your data that gets shared.
3. If you're happy with it, tap **Allow AI coaching**.
4. Try:
   - **Home:** the morning briefing card.
   - **Coach → New conversation:** ask *"How has my weight trended this month?"*
   - **Coach → Weekly review**, and **Reassess my goals**. Any goal change waits for you to tap **Accept**.
   - **Coach → What the coach remembers:** approve or discard what it suggested.

---

## Cost controls (already built in)

| Control | Default | Where to change |
|---|---|---|
| Per-user daily tokens | 60,000 (~30–60 messages) | `ai_config` table |
| Per-user daily requests | 60 | `ai_config` |
| Per-minute requests | 6 | Edge Function code |
| Whole-app monthly tokens | 5,000,000 | `ai_config` |
| Morning briefing | generated once per day, then cached | — |
| Weekly review | once per week unless refreshed | — |
| Your OpenAI monthly budget | set in step 1 | OpenAI dashboard |

To change the model (default `gpt-5-mini`, a low-cost model) or limits:
1. In Supabase → **Table Editor → ai_config**, add a new row with the new values.
2. Set the old row's `is_active` to false.
3. Set the new row's `is_active` to true.

No redeploy is needed. Only one row can be active at a time.

## Troubleshooting

| What you see in the app | Fix |
|---|---|
| "The coach service isn't deployed yet." | Step 3 isn't done, or the deploy failed. Ask Claude to check the deploy run. |
| "The coach isn't set up yet (missing AI provider key)." | Add `OPENAI_API_KEY` (step 2). |
| "The coach couldn't respond right now (insufficient_quota)" | Add credit on OpenAI Billing. |
| "…(model_not_found)" | Your OpenAI account can't use the configured model; change `chat_model` in `ai_config` (see above). |
| "You've reached today's coaching limit." | Working as designed; resets tomorrow, or raise the limit in `ai_config`. |
