-- Retries from a flaky mobile connection must never duplicate.
begin;
select plan(13);
select tests.create_world();

select tests.authenticate_as('dave');

-- create_horse: same key twice -> same result, one row, one membership
create temp table r1 as select api.create_horse('a1a1a1a1-0000-4000-8000-000000000001', 'Retry Rocket', 'Arabian', 2020) as res;
create temp table r2 as select api.create_horse('a1a1a1a1-0000-4000-8000-000000000001', 'Retry Rocket', 'Arabian', 2020) as res;
select is((select res from r2), (select res from r1), 'replay returns the identical response');
select is((select count(*)::int from api.horses where name = 'Retry Rocket'), 1, 'replay created no second horse');
select is((select count(*)::int from api.memberships where resource_id = ((select res from r1) ->> 'id')::uuid), 1,
  'replay created no second owner membership');

-- same key, different payload -> loud conflict (client bug), nothing written
select throws_ok($$select api.create_horse('a1a1a1a1-0000-4000-8000-000000000001', 'Different Horse')$$,
  'PT409', 'idempotency_key_reused', 'reusing a key for a different request is a 409');
select is((select count(*)::int from api.horses where name = 'Different Horse'), 0, 'conflicting request wrote nothing');

-- same key, different operation -> conflict
select throws_ok($$select api.create_stable('a1a1a1a1-0000-4000-8000-000000000001', 'Retry Rocket')$$,
  'PT409', 'idempotency_key_reused', 'a key is bound to one operation');

-- missing key
select throws_ok($$select api.create_horse(null, 'No Key')$$, '22023', 'idempotency_key_required', 'key is mandatory');
reset role;

-- keys are scoped per user: bob using the same uuid is a different request
select tests.authenticate_as('bob');
select isnt((api.create_horse('a1a1a1a1-0000-4000-8000-000000000001', 'Retry Rocket', 'Arabian', 2020) ->> 'id'),
  (select res ->> 'id' from r1), 'same key from another user is independent (no cross-user response leak)');

-- log_training retried three times -> one log
select api.log_training('b2b2b2b2-0000-4000-8000-000000000001', tests.h('thunder'), '2026-10-01T08:00:00Z', 50, 'eventing')
from generate_series(1, 3);
select is((select count(*)::int from api.training_logs where started_at = '2026-10-01T08:00:00Z'), 1,
  'three retries of log_training -> one training log');
reset role;

-- task with side effect retried -> exactly one outbox message
select tests.authenticate_as('erin');
select api.create_stable_task('c3c3c3c3-0000-4000-8000-000000000001', tests.s('oak'), 'Worm all horses', null, null, null, tests.u('erin'))
from generate_series(1, 3);
select is((select count(*)::int from api.stable_tasks where title = 'Worm all horses'), 1, 'one task');
reset role;
select is((select count(*)::int from private.outbox where payload ->> 'title' = 'Worm all horses'), 1,
  'retries enqueue the external side effect exactly once');

-- grant_membership retried -> one membership
select tests.authenticate_as('alice');
select api.grant_membership('d4d4d4d4-0000-4000-8000-000000000001', 'horse', tests.h('thunder'), tests.u('dave'), 'rider')
from generate_series(1, 2);
select is((select count(*)::int from api.memberships where user_id = tests.u('dave') and resource_id = tests.h('thunder')), 1,
  'grant retried -> one membership');
reset role;

-- the idempotency table has the unique constraint backing all of this
select col_is_pk('private', 'idempotency_keys', array['user_id', 'key'], 'idempotency keys are unique per (user, key)');

select * from finish();
rollback;
