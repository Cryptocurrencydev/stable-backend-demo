-- What each persona sees through the api views (RLS evaluated as api_reader
-- with the caller's JWT).
begin;
select plan(30);
select tests.create_world();

-- ---------------------------------------------------------------- owner
select tests.authenticate_as('alice');
select results_eq('select name from api.horses order by name', $$values ('Thunder'::text)$$,
  'owner sees only her horse');
select is((select my_roles from api.horses where id = tests.h('thunder')), array['owner'], 'my_roles = {owner}');
select is((select count(*)::int from api.training_logs), 2, 'owner sees all training logs of her horse');
select is((select count(*)::int from api.training_logs where horse_id = tests.h('pepper')), 0,
  'owner cannot see training logs of another horse');
select is((select count(*)::int from api.sensor_readings), 1, 'owner sees readings of her horse''s sensor only');
select is((select count(*)::int from api.stables), 0, 'horse owner without stable membership does not see the stable');
select is((select count(*)::int from api.stable_tasks), 0, 'horse owner does not see stable tasks');
select results_eq('select qr_code from api.products order by qr_code', $$values ('TESTQR-0002'::text)$$,
  'owner sees her own product, not unregistered or other users'' products');
reset role;

-- ---------------------------------------------------------------- trainer + owner (two contexts)
select tests.authenticate_as('bob');
select results_eq('select name from api.horses order by name', $$values ('Pepper'::text), ('Thunder'::text)$$,
  'bob sees the horse he trains and the horse he owns');
select is((select my_roles from api.horses where id = tests.h('thunder')), array['trainer'], 'bob is trainer on Thunder');
select is((select my_roles from api.horses where id = tests.h('pepper')), array['owner'], 'bob is owner on Pepper');
select is((select count(*)::int from api.training_logs), 3, 'bob sees logs of both horses');
reset role;

-- ---------------------------------------------------------------- viewer
select tests.authenticate_as('carol');
select results_eq('select name from api.horses', $$values ('Thunder'::text)$$, 'viewer sees the horse');
select is((select count(*)::int from api.training_logs), 0, 'viewer cannot see training logs');
select is((select count(*)::int from api.sensors), 0, 'viewer cannot see sensors');
select is((select count(*)::int from api.sensor_readings), 0, 'viewer cannot see sensor readings');
select is((select count(*)::int from api.products), 1, 'viewer sees the product linked to the horse');
select is((select count(*)::int from api.memberships where resource_id = tests.h('thunder')), 4,
  'viewer can see who else is on the horse');
reset role;

-- ---------------------------------------------------------------- rider
select tests.authenticate_as('frank');
select is((select count(*)::int from api.training_logs), 2, 'rider sees training logs');
select is((select count(*)::int from api.sensor_readings), 0, 'rider cannot see sensor data');
reset role;

-- ---------------------------------------------------------------- stranger
select tests.authenticate_as('dave');
select is((select count(*)::int from api.horses), 0, 'stranger sees no horses');
select is(
  (select count(*)::int from api.training_logs) + (select count(*)::int from api.stable_tasks)
  + (select count(*)::int from api.sensors) + (select count(*)::int from api.sensor_readings)
  + (select count(*)::int from api.products) + (select count(*)::int from api.memberships)
  + (select count(*)::int from api.stables),
  0, 'stranger sees nothing in any view');
select is((select count(*)::int from api.horses where id = tests.h('thunder')), 0,
  'stranger cannot fetch a horse by id even when guessing it');
reset role;

-- ---------------------------------------------------------------- stable manager inheritance
select tests.authenticate_as('erin');
select results_eq('select name from api.horses order by name', $$values ('Maple'::text), ('Thunder'::text)$$,
  'stable manager sees every horse boarded at the stable, and only those');
select is((select my_roles from api.horses where id = tests.h('thunder')), array['stable_manager'],
  'manager role is inherited, not stored');
select is((select count(*)::int from api.stable_tasks), 1, 'manager sees stable tasks');
select is((select count(*)::int from api.sensor_readings), 1, 'manager sees sensor data of boarded horses');
select is((select my_role from api.stables where id = tests.s('oak')), 'stable_manager', 'stables.my_role');
reset role;

-- ---------------------------------------------------------------- soft deletes are hidden
update private.horses set deleted_at = now() where id = tests.h('pepper');
select tests.authenticate_as('bob');
select results_eq('select name from api.horses', $$values ('Thunder'::text)$$, 'soft-deleted horse disappears from views');
reset role;

-- ---------------------------------------------------------------- no JWT
select tests.clear_auth();
set local role authenticated;
select is((select count(*)::int from api.horses), 0, 'authenticated role without a sub claim sees nothing');
reset role;

select * from finish();
rollback;
