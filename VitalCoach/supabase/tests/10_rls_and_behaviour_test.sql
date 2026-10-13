-- RLS, isolation, optimistic concurrency, append-only and cascade-deletion tests.
-- Runs with ON_ERROR_STOP; each check raises an exception on failure.
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'alice@example.com'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'bob@example.com');

create or replace function pg_temp.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
end $$;

create or replace function pg_temp.expect_error(sql text, code text, label text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if sqlstate = code or code = '*' then
      raise notice 'PASS %', label; return;
    end if;
    raise exception 'FAIL % — expected %, got % (%)', label, code, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL % — expected error %, statement succeeded', label, code;
end $$;

create or replace function pg_temp.expect_eq(actual bigint, expected bigint, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL % — expected %, got %', label, expected, actual; end if;
  raise notice 'PASS %', label;
end $$;

-- ---------- Alice writes her own data ----------
select pg_temp.as_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
insert into public.user_goals (id, user_id, goal, created_at, client_updated_at, version)
values ('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'strength', now(), now(), 1);
insert into public.user_substances (id, user_id, name, category, status, created_at, client_updated_at, version)
values ('a0000000-0000-4000-8000-000000000002', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Magnesium', 'vitamin_mineral', 'active', now(), now(), 1);
insert into public.actual_administrations (id, user_id, user_substance_id, action, taken_at, time_zone_identifier, recorded_at, client_updated_at)
values ('a0000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a0000000-0000-4000-8000-000000000002', 'taken', now(), 'UTC', now(), now());
select pg_temp.expect_eq((select count(*) from public.user_goals), 1, 'alice sees her goal');
select pg_temp.expect_eq((select count(*) from public.user_goals where server_updated_at is not null), 1, 'server_updated_at set by trigger');

-- Optimistic concurrency
update public.user_goals set note = 'v2', version = 2 where id = 'a0000000-0000-4000-8000-000000000001';
select pg_temp.expect_error($$update public.user_goals set note = 'stale', version = 2 where id = 'a0000000-0000-4000-8000-000000000001'$$, 'PT409', 'stale version rejected');
select pg_temp.expect_error($$update public.user_goals set note = 'skip', version = 9 where id = 'a0000000-0000-4000-8000-000000000001'$$, 'PT409', 'version jump rejected');

-- Upsert path used by PostgREST (insert … on conflict do update)
insert into public.user_goals (id, user_id, goal, created_at, client_updated_at, version)
values ('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'strength', now(), now(), 3)
on conflict (id) do update set goal = excluded.goal, version = excluded.version, client_updated_at = excluded.client_updated_at;
select pg_temp.expect_eq((select version from public.user_goals where id = 'a0000000-0000-4000-8000-000000000001'), 3, 'upsert with next version accepted');
select pg_temp.expect_error($$insert into public.user_goals (id, user_id, goal, created_at, client_updated_at, version)
  values ('a0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'strength', now(), now(), 3)
  on conflict (id) do update set version = excluded.version$$, 'PT409', 'upsert with stale version rejected');

-- Append-only
select pg_temp.expect_error($$update public.actual_administrations set note = 'edit', version = 1 where id = 'a0000000-0000-4000-8000-000000000003'$$, 'PT409', 'administrations are append-only');
select pg_temp.expect_error($$delete from public.user_goals where id = 'a0000000-0000-4000-8000-000000000001'$$, '*', 'no client hard-delete (no privilege/policy)');
select pg_temp.expect_eq((select count(*) from public.user_goals), 1, 'goal still present after delete attempt');

-- Constraint checks
select pg_temp.expect_error($$insert into public.pain_entries (id, user_id, recorded_at, location, severity, client_updated_at)
  values (gen_random_uuid(), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', now(), 'knee_left', 11, now())$$, '23514', 'pain severity > 10 rejected');
select pg_temp.expect_error($$insert into public.substance_regimens (id, user_id, user_substance_id, dose_amount, dose_unit, route, schedule, start_date, created_at, client_updated_at)
  values (gen_random_uuid(), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a0000000-0000-4000-8000-000000000002', 0, 'mg', 'oral', '{}', current_date, now(), now())$$, '23514', 'zero dose rejected');
select pg_temp.expect_error($$insert into public.actual_administrations (id, user_id, user_substance_id, action, time_zone_identifier, recorded_at, client_updated_at)
  values (gen_random_uuid(), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'a0000000-0000-4000-8000-000000000002', 'taken', 'UTC', now(), now())$$, '23514', 'taken without time rejected');
reset role;

-- ---------- Bob cannot see or touch Alice's data ----------
select pg_temp.as_user('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select pg_temp.expect_eq((select count(*) from public.user_goals), 0, 'bob cannot read alice goals');
select pg_temp.expect_eq((select count(*) from public.actual_administrations), 0, 'bob cannot read alice administrations');
update public.user_goals set note = 'pwned', version = 4 where id = 'a0000000-0000-4000-8000-000000000001';
select pg_temp.expect_eq((select count(*) from public.user_goals where note = 'pwned'), 0, 'bob update affects nothing');
select pg_temp.expect_error($$insert into public.user_goals (id, user_id, goal, created_at, client_updated_at)
  values (gen_random_uuid(), 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'fat_loss', now(), now())$$, '42501', 'bob cannot insert as alice');
select pg_temp.expect_error($$insert into public.user_goals (id, user_id, goal, created_at, client_updated_at, version)
  values ('a0000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'fat_loss', now(), now(), 4)
  on conflict (id) do update set note = 'hijack', version = excluded.version$$, '42501', 'bob cannot hijack alice row via upsert');
insert into public.user_goals (id, user_id, goal, created_at, client_updated_at)
values ('b0000000-0000-4000-8000-000000000001', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'longevity', now(), now());
select pg_temp.expect_error($$update public.user_goals set user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', version = 1 where id = 'b0000000-0000-4000-8000-000000000001'$$, '*', 'bob cannot move a row to alice');
reset role;

-- ---------- Anonymous role has no access ----------
set role anon;
select pg_temp.expect_error($$select count(*) from public.user_goals$$, '42501', 'anon cannot read');
reset role;

-- ---------- Unauthenticated "authenticated" role (no sub) sees nothing ----------
select set_config('request.jwt.claims', '{}', false);
set role authenticated;
select pg_temp.expect_eq((select count(*) from public.user_goals), 0, 'missing sub sees nothing');
reset role;

-- ---------- Account deletion cascades ----------
delete from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select pg_temp.expect_eq((select count(*) from public.user_goals where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0, 'cascade removes goals');
select pg_temp.expect_eq((select count(*) from public.actual_administrations where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0, 'cascade removes append-only administrations');
select pg_temp.expect_eq((select count(*) from public.user_substances where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0, 'cascade removes substances');
select pg_temp.expect_eq((select count(*) from public.user_goals where user_id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'), 1, 'other users untouched');

-- ---------- Every RLS-enabled table has policies and RLS forced ----------
select pg_temp.expect_eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not (c.relrowsecurity and c.relforcerowsecurity)), 0, 'all public tables have forced RLS');
-- Every client-accessible table has at least a select policy; ai_config (server-only) has none on purpose.
select pg_temp.expect_eq((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and c.relname <> 'ai_config'
  and (select count(*) from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname and p.cmd = 'SELECT') < 1), 0, 'every client table has a select policy');
select pg_temp.expect_eq((select count(*) from pg_policies where schemaname = 'public' and tablename = 'ai_config'), 0, 'ai_config has no client policies');
