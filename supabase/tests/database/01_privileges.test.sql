-- Least-privilege posture: RLS everywhere, no grants on base tables, api is
-- views + definer functions only, exact EXECUTE allow-lists per role.
begin;
select plan(25);

-- ---------------------------------------------------------------- RLS
select is(
  (select count(*)::int from pg_tables where schemaname = 'private' and not rowsecurity),
  0, 'every table in private has RLS enabled');

select cmp_ok(
  (select count(*)::int from pg_tables where schemaname = 'private'), '>=', 12,
  'private schema contains the base tables');

select is(
  (select count(*)::int from pg_tables t
    where t.schemaname = 'private'
      and not exists (select 1 from pg_policies p where p.schemaname = 'private' and p.tablename = t.tablename)
      and t.tablename <> 'webhook_events'),
  0, 'every private table except webhook_events (owner-only) has at least one policy');

-- ---------------------------------------------------------------- grants on base tables
select is(
  (select count(*)::int
     from pg_class c join pg_namespace n on n.oid = c.relnamespace,
          unnest(array['anon', 'authenticated', 'service_role']) r(role)
    where n.nspname = 'private' and c.relkind = 'r'
      and (has_table_privilege(r.role, c.oid, 'SELECT') or has_table_privilege(r.role, c.oid, 'INSERT')
        or has_table_privilege(r.role, c.oid, 'UPDATE') or has_table_privilege(r.role, c.oid, 'DELETE'))),
  0, 'anon / authenticated / service_role have no privileges on any private table');

select ok(not has_schema_privilege('authenticated', 'private', 'USAGE'), 'authenticated has no USAGE on private');
select ok(not has_schema_privilege('anon', 'private', 'USAGE'), 'anon has no USAGE on private');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'private' and c.relkind = 'r' and has_table_privilege('api_writer', c.oid, 'DELETE')),
  0, 'api_writer can never hard-DELETE (soft deletes only)');

-- ---------------------------------------------------------------- api shape
select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api' and c.relkind in ('r', 'p', 'm', 'f')),
  0, 'api schema contains no tables, only views and functions');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api' and c.relkind = 'v'
      and (has_table_privilege('authenticated', c.oid, 'INSERT')
        or has_table_privilege('authenticated', c.oid, 'UPDATE')
        or has_table_privilege('authenticated', c.oid, 'DELETE'))),
  0, 'api views are read-only for authenticated');

select is(
  (select count(*)::int from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'api' and c.relkind = 'v' and pg_get_userbyid(c.relowner) <> 'api_reader'),
  0, 'every api view is owned by api_reader');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and (not p.prosecdef or p.proconfig is null
      or not exists (select 1 from unnest(p.proconfig) c where c like 'search_path=%'))),
  0, 'every api function is SECURITY DEFINER with a pinned search_path');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and pg_get_userbyid(p.proowner) = 'api_writer'),
  array['complete_stable_task', 'create_horse', 'create_stable', 'create_stable_task', 'delete_horse',
        'delete_training_log', 'grant_membership', 'log_training', 'move_horse', 'register_product',
        'register_sensor', 'revoke_membership', 'sync_sensor_readings', 'update_horse'],
  'all write functions are owned by api_writer');

select ok(
  (select not rolbypassrls and not rolcanlogin and not rolsuper from pg_roles where rolname = 'api_reader')
  and (select not rolbypassrls and not rolcanlogin and not rolsuper from pg_roles where rolname = 'api_writer'),
  'owner roles are NOLOGIN, NOSUPERUSER, NOBYPASSRLS');

-- ---------------------------------------------------------------- EXECUTE allow-lists
select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  array['complete_stable_task', 'create_horse', 'create_stable', 'create_stable_task', 'delete_horse',
        'delete_training_log', 'grant_membership', 'log_training', 'move_horse', 'my_permissions',
        'product_passport', 'register_product', 'register_sensor', 'revoke_membership', 'sync_changes',
        'sync_sensor_readings', 'update_horse'],
  'authenticated can execute exactly the documented api functions');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and has_function_privilege('anon', p.oid, 'EXECUTE')),
  array['product_passport'],
  'anon can execute only the public product passport lookup');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'api' and has_function_privilege('service_role', p.oid, 'EXECUTE')),
  array['outbox_claim', 'outbox_complete', 'outbox_fail', 'record_webhook_event'],
  'service_role can execute only the ops functions');

select is(
  (select array_agg(p.proname::text order by p.proname) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('authenticated', p.oid, 'EXECUTE')),
  array['has_permission', 'horse_roles', 'is_untrusted_probe', 'uid'],
  'authenticated can execute only the guarded app functions that views/policies call implicitly');

select is(
  (select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'app' and has_function_privilege('anon', p.oid, 'EXECUTE')),
  0, 'anon cannot execute any app.* function');

-- ---------------------------------------------------------------- behaviour as client roles
select tests.create_world();

select tests.authenticate_as('alice');
select throws_ok('select * from private.horses', '42501', null, 'authenticated: direct read of private.horses is denied');
select is(app.has_permission(tests.u('bob'), 'horse', tests.h('pepper'), 'update'), false,
  'authenticated: probing ANOTHER user''s permissions always returns false');
select is(app.has_permission(tests.u('alice'), 'horse', tests.h('thunder'), 'update'), true,
  'authenticated: asking about yourself works');
select throws_ok($$insert into api.horses (id, name) values (gen_random_uuid(), 'Sneaky')$$, '42501', null,
  'authenticated: cannot insert through an api view');
select throws_ok($$select api.outbox_claim('me')$$, '42501', null, 'authenticated: cannot call service-role ops functions');
reset role;

select tests.clear_auth();
set local role anon;
select throws_ok('select * from api.horses', '42501', null, 'anon: cannot read api.horses');
select ok((select api.product_passport('TESTQR-0002') ->> 'manufacturer') = 'Fictional Textiles'
          and not (select api.product_passport('TESTQR-0002') ? 'owner_id'),
  'anon: product passport lookup works and exposes no owner');
reset role;

select * from finish();
rollback;
