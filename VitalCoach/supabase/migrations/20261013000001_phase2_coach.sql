-- VitalCoach Phase 2: AI coach.
--
-- Security model
-- * Users can READ their own coach data through PostgREST (RLS).
-- * Conversations, messages, insights and usage are WRITTEN only by the `coach` Edge Function
--   (service role), which sets user_id from the verified JWT. Clients therefore cannot forge
--   assistant messages that would later be fed back to the model.
-- * coach_memory is user-controlled: users may approve, edit, archive and delete their own
--   memories; the coach can only *propose* memories (status 'proposed').
-- * ai_config holds versioned model/prompt settings and budgets; it is not readable by clients.

-- ---------------------------------------------------------------------------
-- Model / prompt configuration (versioned, server-only)
-- ---------------------------------------------------------------------------
create table public.ai_config (
  id integer primary key generated always as identity,
  prompt_version text not null,
  chat_model text not null,
  -- Optional reasoning effort for reasoning models ('minimal','low','medium','high'); null = omit.
  reasoning_effort text,
  max_output_tokens integer not null default 1200 check (max_output_tokens between 100 and 8000),
  daily_token_limit_per_user integer not null default 60000 check (daily_token_limit_per_user > 0),
  daily_request_limit_per_user integer not null default 60 check (daily_request_limit_per_user > 0),
  monthly_token_limit_global bigint not null default 5000000 check (monthly_token_limit_global > 0),
  is_active boolean not null default false,
  created_at timestamptz not null default now(),
  note text
);
-- Exactly one active configuration.
create unique index ai_config_one_active on public.ai_config (is_active) where is_active;
alter table public.ai_config enable row level security;
alter table public.ai_config force row level security;
revoke all on public.ai_config from anon, authenticated;

insert into public.ai_config (prompt_version, chat_model, reasoning_effort, max_output_tokens, is_active, note)
values ('coach-2026-10-13.1', 'gpt-5-mini', 'low', 2500, true,
        'Initial configuration. Change chat_model here (insert a new row and activate it) to switch models without redeploying.');

-- ---------------------------------------------------------------------------
-- Conversations and messages
-- ---------------------------------------------------------------------------
create table public.coach_conversations (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  title text not null default 'Conversation' check (char_length(title) <= 120),
  kind text not null default 'chat' check (kind in ('chat','morning_briefing','weekly_summary','goal_reassessment','checkin_followup')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  archived_at timestamptz
);
create index on public.coach_conversations (user_id, updated_at desc);

create table public.coach_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  conversation_id uuid not null references public.coach_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant','system_notice')),
  content text not null check (char_length(content) <= 20000),
  -- Structured extras from the model: basis of claims, follow-up question, safety flags.
  metadata jsonb not null default '{}' check (jsonb_typeof(metadata) = 'object'),
  model text,
  prompt_version text,
  input_tokens integer,
  output_tokens integer,
  created_at timestamptz not null default now()
);
create index on public.coach_messages (conversation_id, created_at);
create index on public.coach_messages (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- User-controlled memory
-- ---------------------------------------------------------------------------
create table public.coach_memory (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('preference','goal_context','health_context','routine','other')),
  content text not null check (char_length(content) between 1 and 500),
  source text not null check (source in ('user','coach')),
  -- Coach-suggested memories start 'proposed' and are used only after the user approves them.
  status text not null default 'active' check (status in ('proposed','active','archived')),
  source_message_id uuid references public.coach_messages(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.coach_memory (user_id, status);

-- ---------------------------------------------------------------------------
-- Generated insights (briefings, weekly summaries, goal proposals)
-- ---------------------------------------------------------------------------
create table public.generated_insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('morning_briefing','weekly_summary','goal_reassessment','goal_proposal')),
  -- Local calendar date the insight is for (one briefing per day, one summary per week).
  for_date date not null,
  title text not null check (char_length(title) <= 200),
  body text not null check (char_length(body) <= 20000),
  -- e.g. {"add":["fat_loss"],"remove":[],"rationale":"..."} for goal proposals.
  payload jsonb not null default '{}' check (jsonb_typeof(payload) = 'object'),
  status text not null default 'new' check (status in ('new','seen','accepted','dismissed')),
  model text,
  prompt_version text,
  created_at timestamptz not null default now()
);
create unique index generated_insights_one_per_period
  on public.generated_insights (user_id, kind, for_date) where kind in ('morning_briefing','weekly_summary');
create index on public.generated_insights (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Usage accounting (budget enforcement)
-- ---------------------------------------------------------------------------
create table public.ai_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  usage_date date not null,
  requests integer not null default 0,
  input_tokens bigint not null default 0,
  output_tokens bigint not null default 0,
  primary key (user_id, usage_date)
);

-- Atomic increment, callable only by the service role (the Edge Function).
create or replace function public.record_ai_usage(p_user uuid, p_date date, p_input bigint, p_output bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.ai_usage (user_id, usage_date, requests, input_tokens, output_tokens)
  values (p_user, p_date, 1, greatest(p_input, 0), greatest(p_output, 0))
  on conflict (user_id, usage_date) do update
    set requests = public.ai_usage.requests + 1,
        input_tokens = public.ai_usage.input_tokens + excluded.input_tokens,
        output_tokens = public.ai_usage.output_tokens + excluded.output_tokens;
$$;
revoke all on function public.record_ai_usage(uuid, date, bigint, bigint) from public, anon, authenticated;

-- Global monthly total for the cost cap (service role only).
create or replace function public.ai_usage_month_total(p_month_start date)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(sum(input_tokens + output_tokens), 0)::bigint
  from public.ai_usage where usage_date >= p_month_start and usage_date < (p_month_start + interval '1 month');
$$;
revoke all on function public.ai_usage_month_total(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['coach_conversations','coach_messages','coach_memory','generated_insights','ai_usage'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('revoke all on public.%I from authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format($p$create policy "own rows: select" on public.%I for select to authenticated
                      using (user_id = (select auth.uid()))$p$, t);
  end loop;
end $$;

-- Users fully control their memory.
grant insert, update, delete on public.coach_memory to authenticated;
create policy "own rows: insert" on public.coach_memory for insert to authenticated
  with check (user_id = (select auth.uid()) and source = 'user');
create policy "own rows: update" on public.coach_memory for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows: delete" on public.coach_memory for delete to authenticated
  using (user_id = (select auth.uid()));

-- Users may mark insights seen/accepted/dismissed (status only) and archive/delete conversations.
grant update (status) on public.generated_insights to authenticated;
create policy "own rows: update status" on public.generated_insights for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant update (archived_at, title) on public.coach_conversations to authenticated;
grant delete on public.coach_conversations to authenticated;
create policy "own rows: update" on public.coach_conversations for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "own rows: delete" on public.coach_conversations for delete to authenticated
  using (user_id = (select auth.uid()));

-- Keep updated_at fresh on memory edits.
create or replace function public.vc_touch_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin new.updated_at := now(); return new; end; $$;
create trigger coach_memory_touch before update on public.coach_memory
  for each row execute function public.vc_touch_updated_at();
revoke all on function public.vc_touch_updated_at() from public, anon, authenticated;
