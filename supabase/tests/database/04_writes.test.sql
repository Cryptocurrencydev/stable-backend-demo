-- Write functions: validation, permission enforcement, error codes, outbox.
--   PT404 not_found (no read access -> no existence leak)
--   42501 forbidden (can read, may not do this)
--   22023 validation error,  PT409 conflict,  28000 unauthenticated
begin;
select plan(40);
select tests.create_world();

-- ---------------------------------------------------------------- authentication
select tests.clear_auth();
set local role authenticated;
select throws_ok($$select api.create_horse(gen_random_uuid(), 'Ghost')$$, '28000', 'unauthenticated',
  'write without a user is rejected');
reset role;

-- ---------------------------------------------------------------- create + validation
select tests.authenticate_as('dave');
select is((api.create_horse(gen_random_uuid(), 'Biscuit', 'Fjord', 2019) ->> 'name'), 'Biscuit', 'anyone can create a horse');
select is((select my_roles from api.horses where name = 'Biscuit'), array['owner'], 'creator becomes owner');
select throws_ok($$select api.create_horse(gen_random_uuid(), '   ')$$, '22023', 'invalid_name', 'blank name rejected');
select throws_ok($$select api.create_horse(gen_random_uuid(), 'Old', null, 1850)$$, '22023', 'invalid_birth_year',
  'implausible birth year rejected');
select throws_ok($$select api.create_horse(gen_random_uuid(), 'Boarder', null, null, null, tests.s('oak'))$$,
  'PT404', 'not_found', 'cannot board a horse at a stable you are not a member of');
select throws_ok($$select api.create_stable(gen_random_uuid(), 'Dave''s Yard', null, 'germany')$$, '22023', 'invalid_country',
  'country must be ISO alpha-2');
reset role;

-- ---------------------------------------------------------------- training logs
select tests.authenticate_as('dave');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now(), 30, 'dressage')$$,
  'PT404', 'not_found', 'stranger: logging on someone else''s horse looks like not found');
reset role;

select tests.authenticate_as('carol');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now(), 30, 'dressage')$$,
  '42501', 'forbidden', 'viewer: can see the horse but may not log training');
reset role;

select tests.authenticate_as('frank');
select ok((api.log_training(gen_random_uuid(), tests.h('thunder'), now() - interval '1 hour', 40, 'jumping', 'hard') ->> 'id') is not null,
  'rider can log training');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now() + interval '1 day', 30, 'dressage')$$,
  '22023', 'invalid_started_at', 'future session rejected');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now(), 0, 'dressage')$$,
  '22023', 'invalid_duration', 'zero duration rejected');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now(), 30, 'quidditch')$$,
  '22023', 'invalid_discipline', 'unknown discipline rejected');
select throws_ok($$select api.delete_training_log(gen_random_uuid(), '40000000-0000-4000-8000-000000000001')$$,
  '42501', 'forbidden', 'rider cannot delete the trainer''s log');
reset role;

select tests.authenticate_as('bob');
select is((api.delete_training_log(gen_random_uuid(), '40000000-0000-4000-8000-000000000001') ->> 'deleted')::boolean, true,
  'author can delete own log');
reset role;

select tests.authenticate_as('erin');
select throws_ok($$select api.log_training(gen_random_uuid(), tests.h('thunder'), now(), 30, 'dressage')$$,
  '42501', 'forbidden', 'stable manager inherits read but not log_training');
reset role;

-- ---------------------------------------------------------------- horse updates
select tests.authenticate_as('bob');
select throws_ok($$select api.update_horse(gen_random_uuid(), tests.h('thunder'), 'Renamed')$$,
  '42501', 'forbidden', 'trainer cannot rename the horse');
select is((api.update_horse(gen_random_uuid(), tests.h('pepper'), 'Pepper II') ->> 'name'), 'Pepper II',
  'same user CAN rename the horse he owns');
select throws_ok($$select api.delete_horse(gen_random_uuid(), tests.h('thunder'))$$,
  '42501', 'forbidden', 'trainer cannot delete the horse');
reset role;

select tests.authenticate_as('alice');
select throws_ok($$select api.update_horse(gen_random_uuid(), tests.h('pepper'), 'Hijacked')$$,
  'PT404', 'not_found', 'cross-horse: owner of Thunder cannot touch Pepper');
reset role;

-- ---------------------------------------------------------------- memberships
select tests.authenticate_as('bob');
select throws_ok($$select api.grant_membership(gen_random_uuid(), 'horse', tests.h('thunder'), tests.u('dave'), 'viewer')$$,
  '42501', 'forbidden', 'trainer cannot invite members');
reset role;

select tests.authenticate_as('alice');
select is((api.grant_membership(gen_random_uuid(), 'horse', tests.h('thunder'), tests.u('dave'), 'viewer') ->> 'role'), 'viewer',
  'owner can invite a viewer');
select throws_ok($$select api.grant_membership(gen_random_uuid(), 'horse', tests.h('thunder'), tests.u('dave'), 'stable_manager')$$,
  '22023', 'invalid_role', 'stable_manager is not a horse role');
select throws_ok($$select api.grant_membership(gen_random_uuid(), 'horse', tests.h('thunder'), gen_random_uuid(), 'viewer')$$,
  'PT404', 'user_not_found', 'unknown user');
select throws_ok(
  $$select api.revoke_membership(gen_random_uuid(), (select id from api.memberships where user_id = tests.u('alice') and resource_id = tests.h('thunder')))$$,
  'PT409', 'last_owner', 'cannot remove the last owner');
reset role;

select tests.authenticate_as('dave');
select results_eq('select name from api.horses where id = tests.h(''thunder'')', $$values ('Thunder'::text)$$,
  'invited viewer now sees the horse');
reset role;

select tests.authenticate_as('erin');
select throws_ok($$select api.grant_membership(gen_random_uuid(), 'stable', tests.s('oak'), tests.u('frank'), 'owner')$$,
  '42501', 'forbidden', 'stable manager cannot appoint owners');
select is((api.grant_membership(gen_random_uuid(), 'stable', tests.s('oak'), tests.u('frank'), 'rider') ->> 'role'), 'rider',
  'stable manager can add a rider to the stable');
reset role;

-- ---------------------------------------------------------------- stable tasks + outbox
select tests.authenticate_as('carol');
select throws_ok($$select api.create_stable_task(gen_random_uuid(), tests.s('oak'), 'Sweep aisle')$$,
  'PT404', 'not_found', 'non-member cannot create stable tasks');
reset role;

select tests.authenticate_as('erin');
select throws_ok($$select api.create_stable_task(gen_random_uuid(), tests.s('oak'), 'Ride Pepper', null, null, tests.h('pepper'))$$,
  '22023', 'horse_not_in_stable', 'task horse must be boarded at the stable');
select throws_ok($$select api.create_stable_task(gen_random_uuid(), tests.s('oak'), 'Sweep', null, null, null, tests.u('dave'))$$,
  '22023', 'assignee_not_member', 'assignee must be a stable member');
select is((api.create_stable_task(gen_random_uuid(), tests.s('oak'), 'Check Thunder''s shoes', null, now() + interval '1 day',
            tests.h('thunder'), tests.u('frank')) ->> 'status'), 'open', 'manager creates and assigns a task');
reset role;
select is((select count(*)::int from private.outbox where topic = 'task.assigned'), 1,
  'task assignment enqueued an outbox message in the same transaction');

select tests.authenticate_as('frank');
select is((api.complete_stable_task(gen_random_uuid(), (select id from api.stable_tasks where title = 'Check Thunder''s shoes')) ->> 'status'),
  'done', 'stable rider can complete a task');
reset role;
select is((select count(*)::int from private.outbox where topic = 'task.completed'), 1, 'completion enqueued an outbox message');

-- ---------------------------------------------------------------- products (QR) + sensors
select tests.authenticate_as('carol');
select is((api.register_product(gen_random_uuid(), ' testqr-0001 ') ->> 'qr_code'), 'TESTQR-0001',
  'QR registration (input normalised)');
reset role;
select is((select count(*)::int from private.outbox where topic = 'product.registered'), 1, 'registration enqueued outbox message');

select tests.authenticate_as('dave');
select throws_ok($$select api.register_product(gen_random_uuid(), 'TESTQR-0001')$$, 'PT409', 'product_already_registered',
  'cannot register a product someone else owns');
reset role;

select tests.authenticate_as('frank');
select throws_ok($$select api.register_sensor(gen_random_uuid(), tests.h('thunder'), 'NEW-DEV-01')$$, '42501', 'forbidden',
  'rider cannot register sensors');
reset role;

-- ---------------------------------------------------------------- defense in depth
-- Even if a write function forgot its permission check, RLS on the base table
-- still applies to api_writer with the caller's identity.
select tests.authenticate_as('dave');
reset role;
set local role api_writer;
select throws_ok(
  $$insert into private.training_logs (horse_id, author_id, started_at, duration_minutes, discipline)
    values (tests.h('thunder'), tests.u('dave'), now(), 30, 'dressage')$$,
  '42501', null, 'RLS blocks api_writer from inserting for a horse the caller cannot access');
reset role;

select * from finish();
rollback;
