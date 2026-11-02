-- Test helpers. This file runs first (files run in name order) and COMMITS a
-- `tests` schema used by the other files. It only exists in the test database;
-- it is not part of the migrations.
begin;
select plan(1);

create extension if not exists pgtap with schema extensions;
create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role, api_reader, api_writer;
-- test-only: lets a test switch to api_writer and still call pgTAP
grant usage on schema extensions to api_reader, api_writer;

-- Fixed ids for the fixture world ----------------------------------------------
create or replace function tests.u(p_name text) returns uuid language sql immutable as $$
  select case p_name
    when 'alice' then '10000000-0000-4000-8000-00000000000a'  -- owner of Thunder
    when 'bob'   then '10000000-0000-4000-8000-00000000000b'  -- trainer of Thunder, owner of Pepper
    when 'carol' then '10000000-0000-4000-8000-00000000000c'  -- viewer of Thunder
    when 'dave'  then '10000000-0000-4000-8000-00000000000d'  -- stranger
    when 'erin'  then '10000000-0000-4000-8000-00000000000e'  -- stable_manager of Oak Stable
    when 'frank' then '10000000-0000-4000-8000-00000000000f'  -- rider of Thunder
    when 'gina'  then '10000000-0000-4000-8000-000000000010'  -- owner of Oak Stable + Maple
  end::uuid
$$;
create or replace function tests.h(p_name text) returns uuid language sql immutable as $$
  select case p_name
    when 'thunder' then '20000000-0000-4000-8000-000000000001'  -- boarded at Oak
    when 'pepper'  then '20000000-0000-4000-8000-000000000002'  -- no stable
    when 'maple'   then '20000000-0000-4000-8000-000000000003'  -- boarded at Oak
  end::uuid
$$;
create or replace function tests.s(p_name text) returns uuid language sql immutable as $$
  select case p_name when 'oak' then '30000000-0000-4000-8000-000000000001' end::uuid
$$;

-- Act as a signed-in user (what PostgREST does for a request with a JWT) ---------
create or replace function tests.authenticate_as(p_name text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', tests.u(p_name), 'role', 'authenticated')::text, true);
  perform set_config('request.jwt.claim.sub', tests.u(p_name)::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests.clear_auth() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

-- Build the fixture world (call as postgres inside the test transaction) ----------
create or replace function tests.create_world() returns void language plpgsql as $$
declare n text;
begin
  foreach n in array array['alice', 'bob', 'carol', 'dave', 'erin', 'frank', 'gina'] loop
    insert into auth.users (instance_id, id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    values ('00000000-0000-0000-0000-000000000000', tests.u(n), 'authenticated', 'authenticated',
            n || '@example.test', '{"provider":"email","providers":["email"]}', '{}', now(), now());
  end loop;

  insert into private.stables (id, name, city, country, created_by)
  values (tests.s('oak'), 'Oak Stable (test)', 'Testhausen', 'DE', tests.u('gina'));

  insert into private.horses (id, name, breed, birth_year, stable_id, created_by) values
    (tests.h('thunder'), 'Thunder', 'Hanoverian', 2015, tests.s('oak'), tests.u('alice')),
    (tests.h('pepper'),  'Pepper',  'Haflinger',  2018, null,           tests.u('bob')),
    (tests.h('maple'),   'Maple',   'Connemara',  2012, tests.s('oak'), tests.u('gina'));

  insert into private.memberships (user_id, horse_id, stable_id, role) values
    (tests.u('alice'), tests.h('thunder'), null, 'owner'),
    (tests.u('bob'),   tests.h('thunder'), null, 'trainer'),
    (tests.u('carol'), tests.h('thunder'), null, 'viewer'),
    (tests.u('frank'), tests.h('thunder'), null, 'rider'),
    (tests.u('bob'),   tests.h('pepper'),  null, 'owner'),
    (tests.u('gina'),  tests.h('maple'),   null, 'owner'),
    (tests.u('gina'),  null, tests.s('oak'), 'owner'),
    (tests.u('erin'),  null, tests.s('oak'), 'stable_manager');

  insert into private.training_logs (id, horse_id, author_id, started_at, duration_minutes, discipline) values
    ('40000000-0000-4000-8000-000000000001', tests.h('thunder'), tests.u('bob'),   now() - interval '2 days', 45, 'dressage'),
    ('40000000-0000-4000-8000-000000000002', tests.h('thunder'), tests.u('alice'), now() - interval '1 day',  30, 'hacking'),
    ('40000000-0000-4000-8000-000000000003', tests.h('pepper'),  tests.u('bob'),   now() - interval '1 day',  20, 'lunging');

  insert into private.stable_tasks (id, stable_id, horse_id, title, created_by) values
    ('50000000-0000-4000-8000-000000000001', tests.s('oak'), tests.h('thunder'), 'Refill hay net', tests.u('erin'));

  insert into private.sensors (id, horse_id, device_id, label, created_by) values
    ('60000000-0000-4000-8000-000000000001', tests.h('thunder'), 'TEST-TH-01', 'Thunder stall', tests.u('alice')),
    ('60000000-0000-4000-8000-000000000002', tests.h('pepper'),  'TEST-PE-01', 'Pepper stall',  tests.u('bob'));

  insert into private.sensor_readings (sensor_id, device_id, recorded_at, temperature_c, humidity_pct) values
    ('60000000-0000-4000-8000-000000000001', 'TEST-TH-01', now() - interval '1 hour', 18.5, 61),
    ('60000000-0000-4000-8000-000000000002', 'TEST-PE-01', now() - interval '1 hour', 17.0, 70);

  insert into private.products (id, qr_code, gtin, name, manufacturer, category, passport, owner_id, horse_id, registered_at) values
    ('70000000-0000-4000-8000-000000000001', 'TESTQR-0001', '04012345000017', 'Test Saddle', 'Fictional Saddlery', 'saddle', '{"materials":["leather"]}', null, null, null),
    ('70000000-0000-4000-8000-000000000002', 'TESTQR-0002', '04012345000024', 'Test Blanket', 'Fictional Textiles', 'blanket', '{"materials":["polyester"]}', tests.u('alice'), tests.h('thunder'), now()),
    ('70000000-0000-4000-8000-000000000003', 'TESTQR-0003', '04012345000031', 'Test Helmet', 'Fictional Safety', 'helmet', '{}', tests.u('bob'), null, now());
end $$;

grant execute on all functions in schema tests to anon, authenticated, service_role, api_reader, api_writer;

select pass('test helpers installed');
select * from finish();
commit;
