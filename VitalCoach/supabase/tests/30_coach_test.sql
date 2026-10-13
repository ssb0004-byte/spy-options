-- Phase 2 coach tables: isolation, write restrictions, memory control, budget functions.
\set ON_ERROR_STOP on
\set QUIET on

insert into auth.users (id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

create or replace function pg_temp.as_user(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, false);
  execute 'set role authenticated';
end $$;
create or replace function pg_temp.expect_error(sql text, code text, label text) returns void language plpgsql as $$
begin
  begin execute sql;
  exception when others then
    if sqlstate = code or code = '*' then raise notice 'PASS %', label; return; end if;
    raise exception 'FAIL % — expected %, got % (%)', label, code, sqlstate, sqlerrm;
  end;
  raise exception 'FAIL % — expected error %, statement succeeded', label, code;
end $$;
create or replace function pg_temp.expect_eq(actual bigint, expected bigint, label text) returns void language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL % — expected %, got %', label, expected, actual; end if;
  raise notice 'PASS %', label;
end $$;

-- Server (service role / owner) writes coach data for Alice.
insert into public.coach_conversations (id, user_id, title) values ('c0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'Chat');
insert into public.coach_messages (id, user_id, conversation_id, role, content)
values ('d0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'c0000000-0000-4000-8000-000000000001', 'assistant', 'Hello');
insert into public.generated_insights (id, user_id, kind, for_date, title, body)
values ('e0000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'morning_briefing', current_date, 'Today', 'Body');
insert into public.coach_memory (user_id, category, content, source, status)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'preference', 'Prefers short answers', 'coach', 'proposed');
select public.record_ai_usage('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', current_date, 100, 50);
select public.record_ai_usage('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', current_date, 10, 5);
select pg_temp.expect_eq((select requests from public.ai_usage where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 2, 'usage increments atomically');
select pg_temp.expect_eq(public.ai_usage_month_total(date_trunc('month', current_date)::date), 165, 'monthly total sums tokens');
select pg_temp.expect_error($$insert into public.generated_insights (user_id, kind, for_date, title, body)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'morning_briefing', current_date, 'Dup', 'x')$$, '23505', 'one morning briefing per day');

-- Alice
select pg_temp.as_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select pg_temp.expect_eq((select count(*) from public.coach_messages), 1, 'alice reads her messages');
select pg_temp.expect_error($$insert into public.coach_messages (user_id, conversation_id, role, content)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'c0000000-0000-4000-8000-000000000001', 'assistant', 'forged')$$, '42501', 'client cannot write assistant messages');
select pg_temp.expect_error($$insert into public.coach_conversations (user_id) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')$$, '42501', 'client cannot create conversations directly');
select pg_temp.expect_error($$insert into public.coach_memory (user_id, category, content, source) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'other', 'x', 'coach')$$, '42501', 'client cannot insert coach-sourced memory');
insert into public.coach_memory (user_id, category, content, source) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'routine', 'Trains mornings', 'user');
update public.coach_memory set status = 'active' where status = 'proposed';
select pg_temp.expect_eq((select count(*) from public.coach_memory where status = 'active'), 2, 'alice approves and adds memories');
delete from public.coach_memory where content = 'Trains mornings';
select pg_temp.expect_eq((select count(*) from public.coach_memory), 1, 'alice deletes a memory');
update public.generated_insights set status = 'seen' where id = 'e0000000-0000-4000-8000-000000000001';
select pg_temp.expect_eq((select count(*) from public.generated_insights where status = 'seen'), 1, 'alice marks insight seen');
select pg_temp.expect_error($$update public.generated_insights set body = 'tampered'$$, '42501', 'insight body is read-only');
select pg_temp.expect_error($$select public.record_ai_usage('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', current_date, -999999, 0)$$, '42501', 'client cannot call record_ai_usage');
select pg_temp.expect_error($$select * from public.ai_config$$, '42501', 'client cannot read ai_config');
select pg_temp.expect_error($$update public.ai_usage set input_tokens = 0$$, '42501', 'client cannot reset usage');
reset role;

-- Bob sees nothing of Alice's.
select pg_temp.as_user('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select pg_temp.expect_eq((select count(*) from public.coach_messages) + (select count(*) from public.coach_memory)
  + (select count(*) from public.generated_insights) + (select count(*) from public.ai_usage), 0, 'bob sees no coach data of alice');
update public.coach_memory set content = 'pwned';
delete from public.coach_conversations;
reset role;
select pg_temp.expect_eq((select count(*) from public.coach_conversations), 1, 'bob cannot delete alice conversation');
select pg_temp.expect_eq((select count(*) from public.coach_memory where content = 'pwned'), 0, 'bob cannot edit alice memory');

-- Exactly one active config.
select pg_temp.expect_eq((select count(*) from public.ai_config where is_active), 1, 'one active ai_config');
select pg_temp.expect_error($$insert into public.ai_config (prompt_version, chat_model, is_active) values ('x', 'y', true)$$, '23505', 'second active config rejected');

-- Cascade.
delete from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select pg_temp.expect_eq((select count(*) from public.coach_messages) + (select count(*) from public.coach_memory)
  + (select count(*) from public.generated_insights) + (select count(*) from public.ai_usage), 0, 'account deletion removes all coach data');
