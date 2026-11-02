-- The central permission function, table-driven. One TAP test per row.
--   alice  owner of Thunder           bob   trainer of Thunder, owner of Pepper
--   carol  viewer of Thunder          frank rider of Thunder
--   erin   stable_manager of Oak      gina  owner of Oak + Maple
--   dave   stranger                   Thunder + Maple are boarded at Oak, Pepper is not
begin;
select * from no_plan();
select tests.create_world();

select is(
  app.has_permission(tests.u(t.who), t.rtype,
    case t.rtype when 'horse' then tests.h(t.res) when 'stable' then tests.s(t.res) else t.res::uuid end,
    t.action),
  t.expected,
  format('%s %s %s on %s %s', t.who, case when t.expected then 'CAN' else 'cannot' end, t.action, t.rtype, t.res))
from (values
  -- owner: everything on own horse
  ('alice', 'horse', 'thunder', 'read',              true),
  ('alice', 'horse', 'thunder', 'update',            true),
  ('alice', 'horse', 'thunder', 'delete',            true),
  ('alice', 'horse', 'thunder', 'manage_members',    true),
  ('alice', 'horse', 'thunder', 'manage_owners',     true),
  ('alice', 'horse', 'thunder', 'log_training',      true),
  ('alice', 'horse', 'thunder', 'manage_sensors',    true),
  ('alice', 'horse', 'thunder', 'write_media',       true),
  -- context-based: owner of Thunder is a stranger to Pepper
  ('alice', 'horse', 'pepper',  'read',              false),
  ('alice', 'horse', 'pepper',  'log_training',      false),
  -- trainer
  ('bob',   'horse', 'thunder', 'read',              true),
  ('bob',   'horse', 'thunder', 'log_training',      true),
  ('bob',   'horse', 'thunder', 'read_training',     true),
  ('bob',   'horse', 'thunder', 'write_sensor_data', true),
  ('bob',   'horse', 'thunder', 'update',            false),
  ('bob',   'horse', 'thunder', 'delete',            false),
  ('bob',   'horse', 'thunder', 'manage_members',    false),
  ('bob',   'horse', 'thunder', 'manage_sensors',    false),
  -- same user, different context: owner of Pepper
  ('bob',   'horse', 'pepper',  'update',            true),
  ('bob',   'horse', 'pepper',  'manage_members',    true),
  ('bob',   'horse', 'maple',   'read',              false),
  -- rider
  ('frank', 'horse', 'thunder', 'read',              true),
  ('frank', 'horse', 'thunder', 'log_training',      true),
  ('frank', 'horse', 'thunder', 'read_sensor_data',  false),
  ('frank', 'horse', 'thunder', 'write_media',       false),
  ('frank', 'horse', 'thunder', 'update',            false),
  -- viewer
  ('carol', 'horse', 'thunder', 'read',              true),
  ('carol', 'horse', 'thunder', 'read_media',        true),
  ('carol', 'horse', 'thunder', 'read_training',     false),
  ('carol', 'horse', 'thunder', 'log_training',      false),
  ('carol', 'horse', 'thunder', 'write_media',       false),
  ('carol', 'horse', 'thunder', 'update',            false),
  ('carol', 'horse', 'pepper',  'read',              false),
  -- stranger
  ('dave',  'horse', 'thunder', 'read',              false),
  ('dave',  'horse', 'thunder', 'read_media',        false),
  ('dave',  'horse', 'pepper',  'read',              false),
  ('dave',  'stable','oak',     'read',              false),
  -- stable manager: stable rights + inherited rights on boarded horses
  ('erin',  'stable','oak',     'read',              true),
  ('erin',  'stable','oak',     'manage_tasks',      true),
  ('erin',  'stable','oak',     'manage_members',    true),
  ('erin',  'stable','oak',     'manage_owners',     false),
  ('erin',  'stable','oak',     'delete',            false),
  ('erin',  'horse', 'thunder', 'read',              true),
  ('erin',  'horse', 'thunder', 'read_training',     true),
  ('erin',  'horse', 'thunder', 'manage_sensors',    true),
  ('erin',  'horse', 'thunder', 'write_sensor_data', true),
  ('erin',  'horse', 'thunder', 'log_training',      false),
  ('erin',  'horse', 'thunder', 'update',            false),
  ('erin',  'horse', 'thunder', 'delete',            false),
  ('erin',  'horse', 'maple',   'read',              true),
  ('erin',  'horse', 'pepper',  'read',              false),
  -- stable owner also inherits manager rights on boarded horses, not ownership
  ('gina',  'stable','oak',     'delete',            true),
  ('gina',  'horse', 'thunder', 'read',              true),
  ('gina',  'horse', 'thunder', 'update',            false),
  ('gina',  'horse', 'maple',   'update',            true),
  -- horse membership gives no stable rights
  ('alice', 'stable','oak',     'read',              false),
  ('alice', 'stable','oak',     'read_tasks',        false),
  -- child resources resolve to their parent
  ('bob',   'training_log', '40000000-0000-4000-8000-000000000001', 'delete', true),   -- author
  ('alice', 'training_log', '40000000-0000-4000-8000-000000000001', 'delete', true),   -- horse owner
  ('frank', 'training_log', '40000000-0000-4000-8000-000000000001', 'delete', false),  -- other rider
  ('frank', 'training_log', '40000000-0000-4000-8000-000000000001', 'read',   true),
  ('carol', 'training_log', '40000000-0000-4000-8000-000000000001', 'read',   false),  -- viewer
  ('erin',  'training_log', '40000000-0000-4000-8000-000000000001', 'read',   true),   -- inherited
  ('alice', 'training_log', '40000000-0000-4000-8000-000000000003', 'read',   false),  -- Pepper's log
  ('erin',  'stable_task',  '50000000-0000-4000-8000-000000000001', 'complete', true),
  ('erin',  'stable_task',  '50000000-0000-4000-8000-000000000001', 'update',   true),
  ('frank', 'stable_task',  '50000000-0000-4000-8000-000000000001', 'read',     false),  -- not a stable member
  ('alice', 'stable_task',  '50000000-0000-4000-8000-000000000001', 'read',     false),
  ('bob',   'sensor',       '60000000-0000-4000-8000-000000000001', 'write_data', true),
  ('frank', 'sensor',       '60000000-0000-4000-8000-000000000001', 'write_data', false),
  ('erin',  'sensor',       '60000000-0000-4000-8000-000000000001', 'manage',     true),
  ('alice', 'sensor',       '60000000-0000-4000-8000-000000000002', 'read',       false),  -- Pepper's sensor
  ('alice', 'product',      '70000000-0000-4000-8000-000000000002', 'update',     true),   -- own product
  ('carol', 'product',      '70000000-0000-4000-8000-000000000002', 'read',       true),   -- linked to Thunder
  ('carol', 'product',      '70000000-0000-4000-8000-000000000002', 'update',     false),
  ('dave',  'product',      '70000000-0000-4000-8000-000000000002', 'read',       false),
  ('alice', 'product',      '70000000-0000-4000-8000-000000000003', 'read',       false)   -- bob's, unlinked
) as t(who, rtype, res, action, expected);

-- Edge cases
select is(app.has_permission(null, 'horse', tests.h('thunder'), 'read'), false, 'null user has no permissions');
select is(app.has_permission(tests.u('alice'), 'spaceship', tests.h('thunder'), 'read'), false, 'unknown resource type is denied');
select is(app.has_permission(tests.u('alice'), 'horse', gen_random_uuid(), 'read'), false, 'nonexistent resource is denied');
select is(app.has_permission(tests.u('alice'), 'horse', tests.h('thunder'), 'fly'), false, 'unknown action is denied');

-- Revocation takes effect immediately
update private.memberships set revoked_at = now() where user_id = tests.u('erin') and stable_id = tests.s('oak');
select is(app.has_permission(tests.u('erin'), 'horse', tests.h('thunder'), 'read'), false,
  'revoked stable manager loses inherited horse access');
select is(app.has_permission(tests.u('erin'), 'stable', tests.s('oak'), 'read'), false,
  'revoked stable manager loses stable access');
update private.memberships set revoked_at = null where user_id = tests.u('erin') and stable_id = tests.s('oak');

-- Inheritance follows the horse, not a copy of memberships
update private.horses set stable_id = null where id = tests.h('thunder');
select is(app.has_permission(tests.u('erin'), 'horse', tests.h('thunder'), 'read'), false,
  'horse leaving the stable removes the manager''s inherited access');
update private.horses set stable_id = tests.s('oak') where id = tests.h('pepper');
select is(app.has_permission(tests.u('erin'), 'horse', tests.h('pepper'), 'read'), true,
  'horse joining the stable grants the manager inherited access');

-- Effective roles for the mobile UI
select is(array(select r from app.horse_roles(tests.u('bob'), tests.h('thunder')) r), array['trainer'],
  'bob''s effective roles on Thunder');
select is(array(select r from app.horse_roles(tests.u('gina'), tests.h('maple')) r order by r), array['owner', 'stable_manager'],
  'gina is owner of Maple and inherits stable_manager');

select * from finish();
rollback;
