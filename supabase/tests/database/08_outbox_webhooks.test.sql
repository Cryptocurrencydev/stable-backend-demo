-- Outbox claim / retry / dead-letter semantics and idempotent webhook recording.
begin;
select plan(17);
select tests.create_world();

-- produce two outbox messages through real write paths
select tests.authenticate_as('erin');
select api.create_stable_task(gen_random_uuid(), tests.s('oak'), 'Call the farrier', null, null, null, tests.u('erin'));
reset role;
select tests.authenticate_as('alice');
select api.register_product(gen_random_uuid(), 'TESTQR-0001');
reset role;
select is((select count(*)::int from private.outbox where status = 'pending'), 2, 'two pending messages');

-- ---------------------------------------------------------------- access
select tests.authenticate_as('alice');
select throws_ok($$select * from api.outbox_claim('w1')$$, '42501', null, 'users cannot claim outbox messages');
select throws_ok($$select api.record_webhook_event('sensorhub', 'e1', 't', '{}', now())$$, '42501', null,
  'users cannot record webhooks');
reset role;

set local role service_role;

-- ---------------------------------------------------------------- claim
create temp table c1 as select * from api.outbox_claim('w1', 10);
select is((select count(*)::int from c1), 2, 'worker 1 claims both');
select is((select count(*)::int from api.outbox_claim('w2', 10)), 0, 'worker 2 gets nothing: claimed rows are locked');
select is((select array_agg(attempts) from c1), array[1, 1], 'attempt counter incremented on claim');

-- ---------------------------------------------------------------- complete
select ok(api.outbox_complete((select min(id) from c1), 'w1'), 'owner worker completes');
select ok(not api.outbox_complete((select max(id) from c1), 'w2'), 'another worker cannot complete a message it does not hold');

-- ---------------------------------------------------------------- fail -> backoff -> retry -> dead
select is(api.outbox_fail((select max(id) from c1), 'w1', 'HTTP 503'), 'pending', 'failure schedules a retry');
reset role;
select ok((select available_at > now() from private.outbox where id = (select max(id) from c1)),
  'retry is delayed (backoff)');
set local role service_role;
select is((select count(*)::int from api.outbox_claim('w1', 10)), 0, 'not claimable during backoff');
reset role;

-- fast-forward: exhaust attempts
update private.outbox set available_at = now() - interval '1 second', attempts = max_attempts - 1
 where id = (select max(id) from c1);
set local role service_role;
select is((select count(*)::int from api.outbox_claim('w1', 10)), 1, 'claimable again after backoff');
select is(api.outbox_fail((select max(id) from c1), 'w1', 'HTTP 500'), 'dead', 'dead-lettered after max_attempts');
reset role;

-- crashed worker: processing lock older than the timeout is reclaimed
update private.outbox set status = 'processing', locked_by = 'crashed', locked_at = now() - interval '10 minutes'
 where id = (select min(id) from c1);
set local role service_role;
select is((select count(*)::int from api.outbox_claim('w3', 10)), 1, 'stale processing lock is reclaimed');

-- ---------------------------------------------------------------- webhooks
select is(api.record_webhook_event('sensorhub', 'evt_001', 'device.offline', '{"device_id":"TEST-TH-01"}', now()) ->> 'status',
  'recorded', 'first delivery recorded');
select is(api.record_webhook_event('sensorhub', 'evt_001', 'device.offline', '{"device_id":"TEST-TH-01"}', now()) ->> 'status',
  'duplicate', 'replayed delivery is a duplicate, not a second row');
reset role;
select is((select count(*)::int from private.webhook_events where event_id = 'evt_001'), 1, 'exactly one stored event');

select * from finish();
rollback;
