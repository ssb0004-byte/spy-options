-- Phase 3 research tables: isolation, write restrictions, shared cache privacy, cascade delete.
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

-- Server (service role / owner) writes research data for Alice and Bob.
insert into public.research_cache (cache_key, source, query, payload)
values ('https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esearch.fcgi?term=creatine', 'pubmed', 'creatine', '{"esearchresult":{"idlist":["1"]}}');
insert into public.compound_insights (id, user_id, kind, compound_key, compound_name, context_hash, evidence_level, payload)
values ('c1000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'card', 'bpc 157', 'BPC-157', 'abc', 'preclinical_animal', '{"name":"BPC-157"}'),
       ('c1000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'card', 'creatine', 'Creatine', 'def', 'established_human', '{"name":"Creatine"}');
insert into public.research_interests (id, user_id, term) values
  ('d1000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'BPC-157'),
  ('d1000000-0000-4000-8000-000000000002', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'creatine');
insert into public.research_alerts (id, user_id, interest_id, kind, title, summary, citation, citation_id)
values ('e1000000-0000-4000-8000-000000000001', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'd1000000-0000-4000-8000-000000000001',
        'new_meta_analysis', 'New meta-analysis: BPC-157', 'Title (2026)', '{"source":"pubmed","id":"90000011"}', '90000011');

select pg_temp.expect_error($$insert into public.research_interests (user_id, term) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'bpc-157')$$, '23505', 'one interest per term (case-insensitive)');
select pg_temp.expect_error($$insert into public.research_alerts (user_id, interest_id, kind, title, summary, citation, citation_id)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'd1000000-0000-4000-8000-000000000001', 'new_meta_analysis', 'dup', 'dup', '{}', '90000011')$$, '23505', 'an alert is created only once per citation');
select pg_temp.expect_error($$insert into public.compound_insights (user_id, kind, compound_key, compound_name, context_hash, evidence_level, payload)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'card', 'x', 'x', 'h', 'very_strong', '{}')$$, '23514', 'evidence level must be one of the 7 levels');
select pg_temp.expect_error($$insert into public.research_alerts (user_id, interest_id, kind, title, summary, citation, citation_id)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'd1000000-0000-4000-8000-000000000001', 'new_paper', 't', 's', '{}', 'x')$$, '23514', 'only meaningful alert kinds are allowed');

-- Alice
select pg_temp.as_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
select pg_temp.expect_eq((select count(*) from public.compound_insights), 1, 'alice reads only her cards');
select pg_temp.expect_eq((select count(*) from public.research_interests), 1, 'alice reads only her interests');
select pg_temp.expect_eq((select count(*) from public.research_alerts), 1, 'alice reads her alerts');
select pg_temp.expect_error($$select * from public.research_cache$$, '42501', 'client cannot read the shared research cache');
select pg_temp.expect_error($$insert into public.research_cache (cache_key, source, query, payload) values ('k', 'pubmed', 'q', '{}')$$, '42501', 'client cannot write the research cache');
select pg_temp.expect_error($$insert into public.compound_insights (user_id, kind, compound_key, compound_name, context_hash, payload)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'card', 'x', 'X', 'h', '{"evidence":"established_human"}')$$, '42501', 'client cannot write insight cards');
select pg_temp.expect_error($$update public.compound_insights set evidence_level = 'established_human'$$, '42501', 'client cannot alter cards');
select pg_temp.expect_error($$insert into public.research_alerts (user_id, interest_id, kind, title, summary, citation, citation_id)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'd1000000-0000-4000-8000-000000000001', 'new_rct', 'forged', 'forged', '{}', 'f')$$, '42501', 'client cannot create alerts');
select pg_temp.expect_error($$insert into public.research_interests (user_id, term) values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'creatine')$$, '42501', 'interests are added through the function (consent enforced)');
select pg_temp.expect_error($$update public.research_alerts set title = 'tampered'$$, '42501', 'alert content is read-only');
update public.research_alerts set seen_at = now() where id = 'e1000000-0000-4000-8000-000000000001';
select pg_temp.expect_eq((select count(*) from public.research_alerts where seen_at is not null), 1, 'alice marks an alert seen');
reset role;

-- Bob cannot see or change Alice's research data.
select pg_temp.as_user('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
select pg_temp.expect_eq((select count(*) from public.compound_insights where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  + (select count(*) from public.research_interests where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  + (select count(*) from public.research_alerts), 0, 'bob sees none of alice research data');
delete from public.research_interests where id = 'd1000000-0000-4000-8000-000000000001';
delete from public.compound_insights where id = 'c1000000-0000-4000-8000-000000000001';
update public.research_alerts set seen_at = null;
reset role;
select pg_temp.expect_eq((select count(*) from public.research_interests where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  + (select count(*) from public.compound_insights where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 2, 'bob cannot delete alice rows');
select pg_temp.expect_eq((select count(*) from public.research_alerts where seen_at is not null), 1, 'bob cannot edit alice alerts');

-- Alice can unfollow; her alerts for that interest go with it.
select pg_temp.as_user('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
delete from public.research_interests where id = 'd1000000-0000-4000-8000-000000000001';
select pg_temp.expect_eq((select count(*) from public.research_alerts), 0, 'unfollowing removes that interest''s alerts');
reset role;

-- Cascade on account deletion; the shared cache (no user data) is unaffected.
insert into public.research_interests (id, user_id, term) values ('d1000000-0000-4000-8000-000000000003', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'naproxen');
insert into public.research_alerts (user_id, interest_id, kind, title, summary, citation, citation_id)
values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'd1000000-0000-4000-8000-000000000003', 'fda_label_update', 't', 's', '{}', 'set1');
delete from auth.users where id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
select pg_temp.expect_eq((select count(*) from public.compound_insights where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  + (select count(*) from public.research_interests where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa')
  + (select count(*) from public.research_alerts where user_id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), 0, 'account deletion removes all research data');
select pg_temp.expect_eq((select count(*) from public.compound_insights), 1, 'other users keep their cards');
select pg_temp.expect_eq((select count(*) from public.research_cache), 1, 'shared cache is unaffected');
select pg_temp.expect_eq(public.prune_research_cache(), 0, 'cache pruning keeps fresh entries');
select pg_temp.expect_error($$set role authenticated; select public.prune_research_cache()$$, '42501', 'client cannot prune the cache');
reset role;
