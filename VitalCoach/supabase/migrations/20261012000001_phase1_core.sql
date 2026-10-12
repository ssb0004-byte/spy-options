-- VitalCoach Phase 1 schema.
--
-- Design rules
-- * Every user-owned table has user_id → auth.users(id) ON DELETE CASCADE, so deleting the
--   auth user deletes all of their rows.
-- * Row Level Security: a signed-in user can select/insert/update only rows whose user_id is
--   their own auth.uid(). There are no DELETE policies: clients soft-delete (deleted_at) so
--   deletions sync; hard deletion happens only through account deletion (cascade).
-- * Column names equal the iOS app's JSON keys (snake_case) so PostgREST upserts map 1:1.
-- * `version` implements optimistic concurrency: an UPDATE must carry OLD.version + 1, else the
--   trigger raises SQLSTATE PT409, which PostgREST returns as HTTP 409.
-- * Append-only tables (consent ledger, dose administrations, audit) reject UPDATEs.
-- * server_updated_at is set by the server on every write and drives incremental pulls.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Shared trigger functions
-- ---------------------------------------------------------------------------

create or replace function public.vc_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception 'user_id is immutable' using errcode = 'PT403';
    end if;
    if new.version is distinct from old.version + 1 then
      raise exception 'version conflict (have %, got %)', old.version, new.version using errcode = 'PT409';
    end if;
    new.server_created_at := old.server_created_at;
  else
    if new.version < 0 then
      raise exception 'version must be >= 0' using errcode = 'PT400';
    end if;
    new.server_created_at := now();
  end if;
  new.server_updated_at := clock_timestamp();
  return new;
end;
$$;

create or replace function public.vc_reject_update()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Append-only: corrections are new rows that reference the row they supersede.
  raise exception 'records in % are append-only', tg_table_name using errcode = 'PT409';
end;
$$;

-- Helper that applies the standard columns, RLS policies, grants and triggers to a table.
create or replace function public.vc_secure_table(tbl regclass, append_only boolean)
returns void
language plpgsql
set search_path = ''
as $$
declare
  t text := tbl::text;
begin
  execute format('alter table %s enable row level security', t);
  execute format('alter table %s force row level security', t);
  execute format('revoke all on %s from anon', t);
  execute format('grant select, insert, update on %s to authenticated', t);
  execute format($p$create policy "own rows: select" on %s for select to authenticated
                    using (user_id = (select auth.uid()))$p$, t);
  execute format($p$create policy "own rows: insert" on %s for insert to authenticated
                    with check (user_id = (select auth.uid()))$p$, t);
  execute format($p$create policy "own rows: update" on %s for update to authenticated
                    using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()))$p$, t);
  execute format('create trigger vc_before_write before insert or update on %s for each row execute function public.vc_before_write()', t);
  if append_only then
    execute format('create trigger vc_append_only before update on %s for each row execute function public.vc_reject_update()', t);
  end if;
  execute format('create index on %s (user_id, server_updated_at, id)', t);
end;
$$;

-- Standard columns appended to every synced table (kept explicit per table for readability):
--   client_updated_at timestamptz not null, version integer not null default 0,
--   deleted_at timestamptz, server_created_at timestamptz, server_updated_at timestamptz

-- ---------------------------------------------------------------------------
-- Profile, goals, preferences, consent
-- ---------------------------------------------------------------------------

create table public.user_profiles (
  id uuid primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  display_name text check (char_length(display_name) <= 100),
  date_of_birth date,
  physiological_sex text check (physiological_sex in ('female','male','intersex','prefer_not_to_say')),
  sex_context_note text check (char_length(sex_context_note) <= 500),
  height_cm double precision check (height_cm between 100 and 250),
  activity_level text check (activity_level in ('sedentary','light','moderate','active','very_active')),
  medical_conditions jsonb not null default '[]' check (jsonb_typeof(medical_conditions) = 'array'),
  allergies jsonb not null default '[]' check (jsonb_typeof(allergies) = 'array'),
  injuries jsonb not null default '[]' check (jsonb_typeof(injuries) = 'array'),
  baseline_pain smallint check (baseline_pain between 0 and 10),
  baseline_energy smallint check (baseline_energy between 1 and 5),
  baseline_mobility smallint check (baseline_mobility between 1 and 5),
  baseline_cognition smallint check (baseline_cognition between 1 and 5),
  onboarding_completed_at timestamptz,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz,
  constraint profile_id_is_user check (id = user_id)
);
select public.vc_secure_table('public.user_profiles', false);

create table public.user_goals (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  goal text not null,
  priority smallint check (priority between 1 and 20),
  note text check (char_length(note) <= 1000),
  is_active boolean not null default true,
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.user_goals', false);

create table public.user_preferences (
  id uuid primary key,
  user_id uuid not null unique references auth.users(id) on delete cascade,
  unit_system text not null check (unit_system in ('metric','imperial')),
  coach_personality text not null,
  notifications jsonb not null default '{}' check (jsonb_typeof(notifications) = 'object'),
  weekly_check_in_weekday smallint not null default 1 check (weekly_check_in_weekday between 1 and 7),
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz,
  constraint preferences_id_is_user check (id = user_id)
);
select public.vc_secure_table('public.user_preferences', false);

create table public.consent_records (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  consent_type text not null check (consent_type in ('terms_and_age','cloud_sync','ai_processing','progress_photo_storage')),
  granted boolean not null,
  document_version integer not null check (document_version >= 0),
  recorded_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.consent_records', true);

-- ---------------------------------------------------------------------------
-- Measurements and check-ins
-- ---------------------------------------------------------------------------

create table public.health_measurements (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  value double precision not null check (value = value and value not in ('Infinity'::float8, '-Infinity'::float8)),
  unit text not null,
  start_at timestamptz not null,
  end_at timestamptz not null check (end_at >= start_at),
  source_kind text not null check (source_kind in ('healthkit','manual','derived')),
  source_name text check (char_length(source_name) <= 200),
  source_bundle_id text check (char_length(source_bundle_id) <= 200),
  external_id text check (char_length(external_id) <= 200),
  quality text not null check (quality in ('measured','estimated','self_reported','derived')),
  note text check (char_length(note) <= 1000),
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.health_measurements', false);
create unique index health_measurements_external_unique
  on public.health_measurements (user_id, external_id) where external_id is not null and source_kind = 'healthkit';
create index on public.health_measurements (user_id, kind, start_at);

create table public.symptom_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  recorded_at timestamptz not null,
  local_date date not null,
  wellbeing smallint check (wellbeing between 1 and 5),
  energy smallint check (energy between 1 and 5),
  cognitive_clarity smallint check (cognitive_clarity between 1 and 5),
  stiffness smallint check (stiffness between 0 and 10),
  mobility_limitations text check (char_length(mobility_limitations) <= 1000),
  side_effects_note text check (char_length(side_effects_note) <= 2000),
  note text check (char_length(note) <= 2000),
  is_weekly boolean not null default false,
  question_set_version integer not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.symptom_entries', false);

create table public.pain_entries (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  symptom_entry_id uuid references public.symptom_entries(id) on delete set null,
  recorded_at timestamptz not null,
  location text not null,
  location_detail text check (char_length(location_detail) <= 200),
  severity smallint not null check (severity between 0 and 10),
  stiffness smallint check (stiffness between 0 and 10),
  functional_impact text check (functional_impact in ('none','mild','moderate','severe')),
  note text check (char_length(note) <= 1000),
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.pain_entries', false);

-- ---------------------------------------------------------------------------
-- Substances, regimens and administrations
-- ---------------------------------------------------------------------------

create table public.user_substances (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 200),
  aliases jsonb not null default '[]' check (jsonb_typeof(aliases) = 'array'),
  category text not null check (category in ('prescription','otc','vitamin_mineral','sports_supplement','peptide','hormone','compounded','other')),
  formulation text check (char_length(formulation) <= 300),
  indication text check (char_length(indication) <= 500),
  status text not null check (status in ('planned','active','paused','completed','discontinued')),
  is_prescribed boolean not null default false,
  notes text check (char_length(notes) <= 2000),
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.user_substances', false);

create table public.substance_regimens (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  user_substance_id uuid not null references public.user_substances(id) on delete cascade,
  dose_amount numeric(14,6) not null check (dose_amount > 0),
  dose_unit text not null check (dose_unit in ('mcg','mg','g','mL','IU','units','capsule','tablet','softgel','drop','spray','puff','patch','scoop','serving')),
  route text not null,
  schedule jsonb not null check (jsonb_typeof(schedule) = 'object'),
  start_date date not null,
  end_date date check (end_date is null or end_date >= start_date),
  supersedes_id uuid,
  change_reason text check (char_length(change_reason) <= 500),
  concentration_amount numeric(14,6) check (concentration_amount is null or concentration_amount > 0),
  concentration_unit text,
  reminders_enabled boolean not null default true,
  created_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.substance_regimens', false);

-- Planned administrations are derived deterministically from versioned regimens (see
-- docs/ARCHITECTURE.md), so no scheduled_administrations table is needed in Phase 1.
create table public.actual_administrations (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  user_substance_id uuid not null references public.user_substances(id) on delete cascade,
  regimen_id uuid references public.substance_regimens(id) on delete set null,
  occurrence_key text check (char_length(occurrence_key) <= 120),
  scheduled_for timestamptz,
  action text not null check (action in ('taken','skipped','missed','voided')),
  taken_at timestamptz,
  dose_amount numeric(14,6) check (dose_amount is null or dose_amount > 0),
  dose_unit text,
  route text,
  site text check (char_length(site) <= 100),
  note text check (char_length(note) <= 1000),
  supersedes_id uuid,
  time_zone_identifier text not null,
  recorded_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz,
  constraint taken_has_time check (action <> 'taken' or taken_at is not null)
);
select public.vc_secure_table('public.actual_administrations', true);
create index on public.actual_administrations (user_id, occurrence_key);

create table public.adverse_effect_reports (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  user_substance_id uuid references public.user_substances(id) on delete set null,
  summary text not null check (char_length(summary) between 1 and 1000),
  severity text not null check (severity in ('mild','moderate','severe')),
  onset_at timestamptz not null,
  resolved_at timestamptz,
  note text check (char_length(note) <= 2000),
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.adverse_effect_reports', false);

create table public.audit_events (
  id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  target_entity text not null,
  target_id uuid not null,
  action text not null check (char_length(action) <= 50),
  summary text not null check (char_length(summary) <= 300),
  occurred_at timestamptz not null,
  client_updated_at timestamptz not null,
  version integer not null default 0,
  deleted_at timestamptz,
  server_created_at timestamptz,
  server_updated_at timestamptz
);
select public.vc_secure_table('public.audit_events', true);

-- The helper is only needed during migration.
drop function public.vc_secure_table(regclass, boolean);
revoke all on function public.vc_before_write() from public, anon, authenticated;
revoke all on function public.vc_reject_update() from public, anon, authenticated;
