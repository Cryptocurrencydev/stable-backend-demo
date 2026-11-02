-- Offline batch upload of sensor readings: partial acceptance, per-row reject
-- reasons, idempotency per (device_id, recorded_at) and per idempotency key.
begin;
select plan(19);
select tests.create_world();

create temp table input as
select jsonb_build_array(
  /* 0 ok           */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '30 minutes', 'temperature_c', 19.2, 'humidity_pct', 58),
  /* 1 ok           */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '20 minutes', 'temperature_c', 19.4),
  /* 2 dup in batch */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '20 minutes', 'temperature_c', 79.9),
  /* 3 dup of stored*/ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '1 hour', 'temperature_c', 18.5),
  /* 4 unknown      */ jsonb_build_object('device_id', 'NOPE-0000', 'recorded_at', now(), 'temperature_c', 20),
  /* 5 future       */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() + interval '1 day', 'temperature_c', 20),
  /* 6 temp range   */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '10 minutes', 'temperature_c', 120),
  /* 7 humid range  */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '9 minutes', 'humidity_pct', 140),
  /* 8 not object   */ to_jsonb('garbage'::text),
  /* 9 bad ts       */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', 'yesterday-ish', 'temperature_c', 20),
  /*10 no value     */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '8 minutes'),
  /*11 not his      */ jsonb_build_object('device_id', 'TEST-PE-01', 'recorded_at', now() - interval '7 minutes', 'temperature_c', 21),
  /*12 too old      */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '200 days', 'temperature_c', 21),
  /*13 heat         */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '5 minutes', 'temperature_c', 33.5),
  /*14 heat         */ jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '4 minutes', 'temperature_c', 34.1)
) as b;
grant select on input to authenticated;

select tests.authenticate_as('alice');   -- owner of Thunder: may write Thunder's sensor data, not Pepper's
create temp table batch1 as
select api.sync_sensor_readings('e5e5e5e5-0000-4000-8000-000000000001', (select b from input)) as res;

select is((select (res ->> 'received')::int from batch1), 15, 'all rows received');
select is((select (res ->> 'accepted')::int from batch1), 4, 'valid rows accepted (0, 1, 13, 14)');
select is((select (res ->> 'duplicates')::int from batch1), 2, 'in-batch and already-stored duplicates are no-ops');
select results_eq(
  $$select (r ->> 'index')::int, r ->> 'reason' from batch1, jsonb_array_elements(res -> 'rejected') r order by 1$$,
  $$values (4, 'unknown_device'), (5, 'recorded_at_in_future'), (6, 'temperature_out_of_range'),
           (7, 'humidity_out_of_range'), (8, 'invalid_row'), (9, 'invalid_value'), (10, 'no_measurement'),
           (11, 'unknown_device'), (12, 'recorded_at_too_old')$$,
  'each invalid row is rejected with its index and a machine-readable reason');
select is((select count(*)::int from api.sensor_readings where device_id = 'TEST-TH-01'), 5,
  'Thunder''s sensor has the stored reading + 4 new');
select is(
  (select temperature_c from api.sensor_readings
    where device_id = 'TEST-TH-01' and recorded_at = (select (b -> 1 ->> 'recorded_at')::timestamptz from input)),
  19.40::numeric(5, 2), 'first write wins: the in-batch duplicate (79.9) did not overwrite');

-- replay with the SAME key -> identical report, nothing new
select is(api.sync_sensor_readings('e5e5e5e5-0000-4000-8000-000000000001', (select b from input)),
  (select res from batch1), 'same idempotency key -> identical stored report');

-- replay with a NEW key (client lost the response and re-sent) -> all duplicates
create temp table batch2 as
select api.sync_sensor_readings('e5e5e5e5-0000-4000-8000-000000000002', (select b from input)) as res;
select is((select (res ->> 'accepted')::int from batch2), 0, 'resend with a new key accepts nothing new');
select is((select (res ->> 'duplicates')::int from batch2), 6, 'previously accepted rows are reported as duplicates');
select is((select count(*)::int from api.sensor_readings where device_id = 'TEST-TH-01'), 5, 'still 5 readings');

-- request-level validation
select throws_ok($$select api.sync_sensor_readings(gen_random_uuid(), '{"device_id":"x"}'::jsonb)$$, '22023',
  'readings_must_be_array', 'payload must be an array');
select throws_ok($$select api.sync_sensor_readings(gen_random_uuid(), '[]'::jsonb)$$, '22023',
  'invalid_batch_size', 'empty batch rejected');
select throws_ok(
  $$select api.sync_sensor_readings(gen_random_uuid(),
     (select jsonb_agg(jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - make_interval(secs => g), 'temperature_c', 20))
        from generate_series(1, 1001) g))$$,
  '22023', 'invalid_batch_size', 'batch larger than 1000 rejected');
reset role;

select is((select count(*)::int from private.sensor_readings where device_id = 'TEST-PE-01'), 1,
  'the row for Pepper''s sensor (alice cannot see it) was not stored');
select is((select count(*)::int from private.outbox where topic = 'sensor.heat_alert'), 1,
  'one heat alert per sensor per batch, none on resend');
select is((select (payload ->> 'max_temperature_c')::numeric from private.outbox where topic = 'sensor.heat_alert'), 34.1,
  'alert carries the batch maximum');

-- a trainer may also upload
select tests.authenticate_as('bob');
select is(
  (api.sync_sensor_readings(gen_random_uuid(),
     jsonb_build_array(jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '2 minutes', 'temperature_c', 20)))
   ->> 'accepted')::int,
  1, 'trainer can upload for the horse he trains');
reset role;

-- a rider has no sensor rights: their uploads are rejected, not stored
select tests.authenticate_as('frank');
select is(
  (api.sync_sensor_readings(gen_random_uuid(),
     jsonb_build_array(jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '1 minute', 'temperature_c', 20)))
   -> 'rejected' -> 0 ->> 'reason'),
  'unknown_device', 'rider cannot upload sensor data (device not visible to them)');
reset role;

-- stable manager inherits write_sensor_data
select tests.authenticate_as('erin');
select is(
  (api.sync_sensor_readings(gen_random_uuid(),
     jsonb_build_array(jsonb_build_object('device_id', 'TEST-TH-01', 'recorded_at', now() - interval '1 minute', 'temperature_c', 20)))
   ->> 'accepted')::int,
  1, 'stable manager can upload for a boarded horse');
reset role;

select * from finish();
rollback;
