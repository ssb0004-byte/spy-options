-- VitalCoach Phase 3: research (Compound Insight Cards, discovery, followed interests, alerts).
--
-- Security model
-- * research_cache is a SHARED cache of public research-API responses (PubMed, ClinicalTrials.gov,
--   openFDA). It contains no user data (queries carry only compound/topic terms). Service-only:
--   clients can neither read nor write it.
-- * compound_insights, research_interests and research_alerts are per user (RLS). Cards, alerts
--   and interests are WRITTEN only by the `research` Edge Function (service role), which sets
--   user_id from the verified JWT and enforces AI consent. Users can read and delete their own
--   rows, and mark alerts seen.
-- * Everything per-user is removed with the account (ON DELETE CASCADE).

-- ---------------------------------------------------------------------------
-- Shared research-API cache (service only)
-- ---------------------------------------------------------------------------
create table public.research_cache (
  cache_key text primary key check (char_length(cache_key) <= 2000),   -- request URL without any API key
  source text not null check (source in ('pubmed','clinicaltrials','fda_label')),
  query text not null check (char_length(query) <= 200),                -- the compound/topic term
  payload jsonb not null,
  fetched_at timestamptz not null default now()
);
create index on public.research_cache (fetched_at);
alter table public.research_cache enable row level security;
alter table public.research_cache force row level security;
revoke all on public.research_cache from anon, authenticated;

-- Housekeeping: drop cache entries older than 30 days (TTL in the function is 7 days).
create or replace function public.prune_research_cache()
returns integer language sql security definer set search_path = '' as $$
  with d as (delete from public.research_cache where fetched_at < now() - interval '30 days' returning 1)
  select count(*)::integer from d;
$$;
revoke all on function public.prune_research_cache() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Per-user cached cards and discovery results
-- ---------------------------------------------------------------------------
create table public.compound_insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('card','discovery')),
  compound_key text not null check (char_length(compound_key) between 1 and 120),
  compound_name text not null check (char_length(compound_name) <= 160),
  -- Hash of the personal context the card was written for (question, routine, conditions, goals).
  context_hash text not null check (char_length(context_hash) <= 64),
  evidence_level text check (evidence_level in ('established_human','moderate_human','preliminary_human',
    'preclinical_animal','in_vitro_mechanistic','anecdotal_community','insufficient')),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  model text,
  prompt_version text,
  last_verified_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create index on public.compound_insights (user_id, kind, compound_key, context_hash, created_at desc);
create index on public.compound_insights (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Followed compounds/topics and update alerts
-- ---------------------------------------------------------------------------
create table public.research_interests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null default 'compound' check (kind in ('compound','topic')),
  term text not null check (char_length(term) between 2 and 80),
  display_name text check (char_length(display_name) <= 80),
  -- Snapshot of what was seen at the last check: {"pubmed":[ids],"trials":{nct:{status,has_results}},"label":{set_id,effective_time}}
  last_seen jsonb check (last_seen is null or jsonb_typeof(last_seen) = 'object'),
  last_checked_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index research_interests_unique_term on public.research_interests (user_id, lower(term));

create table public.research_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  interest_id uuid not null references public.research_interests(id) on delete cascade,
  kind text not null check (kind in ('new_meta_analysis','new_systematic_review','new_rct','fda_label_update','trial_results_posted','trial_completed')),
  title text not null check (char_length(title) <= 200),
  summary text not null check (char_length(summary) <= 1000),
  citation jsonb not null check (jsonb_typeof(citation) = 'object'),
  citation_id text not null check (char_length(citation_id) <= 80),
  created_at timestamptz not null default now(),
  seen_at timestamptz,
  constraint research_alerts_once unique (interest_id, kind, citation_id)
);
create index on public.research_alerts (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['compound_insights','research_interests','research_alerts'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke all on public.%I from authenticated', t);
    execute format('grant select, delete on public.%I to authenticated', t);
    execute format($p$create policy "own rows: select" on public.%I for select to authenticated
                      using (user_id = (select auth.uid()))$p$, t);
    execute format($p$create policy "own rows: delete" on public.%I for delete to authenticated
                      using (user_id = (select auth.uid()))$p$, t);
  end loop;
end $$;

-- Users may mark their alerts as seen (seen_at only).
grant update (seen_at) on public.research_alerts to authenticated;
create policy "own rows: update seen" on public.research_alerts for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- The coach prompt/output schema gained red-flag triage and research_topics: record a new
-- prompt version on the active configuration (model settings unchanged).
update public.ai_config set prompt_version = 'coach-2026-10-14.1' where is_active;
