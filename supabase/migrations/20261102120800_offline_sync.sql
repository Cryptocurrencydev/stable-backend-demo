-- =============================================================================
-- 0009 · Offline-first sync
--
--   api.sync_sensor_readings  batch upload, idempotent per (device_id, recorded_at),
--                             accepts valid rows, reports rejected rows by index
--   api.sync_changes          delta pull since a (sync_ts, id) cursor, including
--                             soft-delete tombstones and access-change handling
-- =============================================================================

create or replace function api.sync_sensor_readings(p_idempotency_key uuid, p_readings jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_max_batch   constant int := 1000;
  c_heat_alert  constant numeric := 32.0;   -- stall temperature (°C) that triggers an alert
  v_user        uuid := app.require_user();
  v_cached      jsonb;
  v_item        jsonb;
  v_idx         int := -1;
  v_device      text;
  v_ts          timestamptz;
  v_temp        numeric;
  v_hum         numeric;
  v_sensor      uuid;
  v_reason      text;
  v_accepted    int := 0;
  v_duplicates  int := 0;
  v_rejected    jsonb := '[]'::jsonb;
  v_alerts      jsonb := '{}'::jsonb;   -- sensor_id -> max temperature in this batch
  v_key         text;
  v_result      jsonb;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'sync_sensor_readings', p_readings);
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(jsonb_typeof(p_readings) = 'array', 'readings_must_be_array');
  perform app.check_arg(jsonb_array_length(p_readings) between 1 and c_max_batch, 'invalid_batch_size',
    format('batch must contain 1-%s readings', c_max_batch));

  for v_item in select value from jsonb_array_elements(p_readings)
  loop
    v_idx := v_idx + 1;
    v_reason := null;
    v_device := null; v_ts := null; v_temp := null; v_hum := null; v_sensor := null;

    if jsonb_typeof(v_item) <> 'object' then
      v_reason := 'invalid_row';
    else
      v_device := v_item ->> 'device_id';
      begin
        v_ts   := (v_item ->> 'recorded_at')::timestamptz;
        v_temp := (v_item ->> 'temperature_c')::numeric;
        v_hum  := (v_item ->> 'humidity_pct')::numeric;
      exception when others then
        v_reason := 'invalid_value';
      end;
    end if;

    if v_reason is null then
      v_reason := case
        when v_device is null or v_device !~ '^[A-Za-z0-9:_-]{4,64}$' then 'invalid_device_id'
        when v_ts is null                                       then 'missing_recorded_at'
        when v_ts > now() + interval '5 minutes'                then 'recorded_at_in_future'
        when v_ts < now() - interval '90 days'                  then 'recorded_at_too_old'
        when v_temp is null and v_hum is null                   then 'no_measurement'
        when v_temp is not null and v_temp not between -50 and 80  then 'temperature_out_of_range'
        when v_hum  is not null and v_hum  not between 0 and 100   then 'humidity_out_of_range'
      end;
    end if;

    if v_reason is null then
      -- RLS hides sensors the caller cannot see, so other people's devices are 'unknown_device'
      select s.id into v_sensor from private.sensors s where s.device_id = v_device and s.deleted_at is null;
      if v_sensor is null then
        v_reason := 'unknown_device';
      elsif not app.has_permission(v_user, 'sensor', v_sensor, 'write_data') then
        v_reason := 'forbidden';
      end if;
    end if;

    if v_reason is not null then
      v_rejected := v_rejected || jsonb_build_object(
        'index', v_idx, 'device_id', v_device, 'recorded_at', v_item ->> 'recorded_at', 'reason', v_reason);
      continue;
    end if;

    insert into private.sensor_readings (sensor_id, device_id, recorded_at, temperature_c, humidity_pct)
    values (v_sensor, v_device, v_ts, round(v_temp, 2), round(v_hum, 2))
    on conflict (device_id, recorded_at) do nothing;

    if found then
      v_accepted := v_accepted + 1;
      if v_temp >= c_heat_alert then
        v_key := v_sensor::text;
        v_alerts := jsonb_set(v_alerts, array[v_key],
          to_jsonb(greatest(v_temp, coalesce((v_alerts ->> v_key)::numeric, v_temp))));
      end if;
    else
      v_duplicates := v_duplicates + 1;
    end if;
  end loop;

  -- one alert per sensor per batch, enqueued in the same transaction
  for v_key in select jsonb_object_keys(v_alerts)
  loop
    perform app.enqueue_outbox('sensor.heat_alert', 'sensor', v_key::uuid, jsonb_build_object(
      'sensor_id', v_key::uuid, 'max_temperature_c', (v_alerts ->> v_key)::numeric, 'threshold_c', c_heat_alert));
  end loop;

  v_result := jsonb_build_object(
    'received', v_idx + 1,
    'accepted', v_accepted,
    'duplicates', v_duplicates,
    'rejected', v_rejected);
  return app.idempotency_finish(p_idempotency_key, v_result);
end;
$$;

-- -----------------------------------------------------------------------------
-- Delta sync.
--
-- Each row carries a sync_ts. For an entity that is simply edited it equals
-- updated_at. When the caller GAINS access to a resource (new membership, or
-- their stable takes in a horse) the entity and all its children get
-- sync_ts = greatest(updated_at, membership.updated_at), so rows that were
-- last edited before the cursor are still delivered. When access is LOST the
-- client receives the revoked membership as a tombstone and purges locally.
--
-- Cursor: strictly greater than (p_since_ts, p_since_id), ordered by
-- (sync_ts, id). Pass the last row's (sync_ts, id) to get the next page; an
-- empty page means caught up.
-- -----------------------------------------------------------------------------
create or replace function api.sync_changes(
  p_since_ts timestamptz default null,
  p_since_id uuid        default null,
  p_limit    int         default 500
)
returns table (
  entity   text,
  id       uuid,
  sync_ts  timestamptz,
  deleted  boolean,
  data     jsonb
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_user  uuid := app.require_user();
  v_ts    timestamptz := coalesce(p_since_ts, '-infinity'::timestamptz);
  v_id    uuid := coalesce(p_since_id, '00000000-0000-0000-0000-000000000000'::uuid);
  v_limit int := least(greatest(coalesce(p_limit, 500), 1), 1000);
begin
  return query
  with my_m as (
    select m.* from private.memberships m where m.user_id = v_user
  ),
  stable_access as (
    select m.stable_id, max(m.updated_at) as granted_at
    from my_m m where m.stable_id is not null and m.revoked_at is null
    group by m.stable_id
  ),
  horse_access as (
    select x.horse_id, max(x.granted_at) as granted_at from (
      select m.horse_id, m.updated_at as granted_at
      from my_m m where m.horse_id is not null and m.revoked_at is null
      union all
      select h.id, greatest(sa.granted_at, h.updated_at)
      from private.horses h
      join my_m m on m.stable_id = h.stable_id and m.revoked_at is null and m.role in ('owner', 'stable_manager')
      join stable_access sa on sa.stable_id = h.stable_id
    ) x group by x.horse_id
  ),
  changes as (
    -- memberships: only the caller's own, including revocations (= lost access)
    select 'membership'::text as entity, m.id, m.updated_at as sync_ts, m.revoked_at is not null as deleted,
           jsonb_build_object('user_id', m.user_id,
             'resource_type', case when m.horse_id is not null then 'horse' else 'stable' end,
             'resource_id', coalesce(m.horse_id, m.stable_id), 'role', m.role) as data
    from my_m m

    union all
    select 'stable', s.id, greatest(s.updated_at, sa.granted_at), s.deleted_at is not null,
           case when s.deleted_at is null then jsonb_build_object('name', s.name, 'city', s.city, 'country', s.country) end
    from private.stables s
    join stable_access sa on sa.stable_id = s.id

    union all
    select 'horse', h.id, greatest(h.updated_at, ha.granted_at), h.deleted_at is not null,
           case when h.deleted_at is null then jsonb_build_object('name', h.name, 'breed', h.breed,
             'birth_year', h.birth_year, 'color', h.color, 'stable_id', h.stable_id) end
    from private.horses h
    join horse_access ha on ha.horse_id = h.id

    union all
    select 'training_log', t.id, greatest(t.updated_at, ha.granted_at), t.deleted_at is not null,
           case when t.deleted_at is null then jsonb_build_object('horse_id', t.horse_id, 'author_id', t.author_id,
             'started_at', t.started_at, 'duration_minutes', t.duration_minutes, 'discipline', t.discipline,
             'intensity', t.intensity, 'notes', t.notes) end
    from private.training_logs t      -- RLS: read_training required
    join horse_access ha on ha.horse_id = t.horse_id

    union all
    select 'stable_task', t.id, greatest(t.updated_at, sa.granted_at), t.deleted_at is not null,
           case when t.deleted_at is null then jsonb_build_object('stable_id', t.stable_id, 'horse_id', t.horse_id,
             'title', t.title, 'details', t.details, 'due_at', t.due_at, 'assigned_to', t.assigned_to,
             'status', t.status, 'completed_by', t.completed_by, 'completed_at', t.completed_at) end
    from private.stable_tasks t       -- RLS: read_tasks required
    join stable_access sa on sa.stable_id = t.stable_id

    union all
    select 'sensor', s.id, greatest(s.updated_at, ha.granted_at), s.deleted_at is not null,
           case when s.deleted_at is null then jsonb_build_object('horse_id', s.horse_id,
             'device_id', s.device_id, 'label', s.label) end
    from private.sensors s            -- RLS: read_sensor_data / manage_sensors required
    join horse_access ha on ha.horse_id = s.horse_id

    union all
    select 'product', p.id, greatest(p.updated_at, coalesce(ha.granted_at, '-infinity')), p.deleted_at is not null,
           case when p.deleted_at is null then jsonb_build_object('qr_code', p.qr_code, 'name', p.name,
             'manufacturer', p.manufacturer, 'category', p.category, 'horse_id', p.horse_id,
             'owner_id', p.owner_id, 'registered_at', p.registered_at) end
    from private.products p           -- RLS: owner, or reader of the linked horse
    left join horse_access ha on ha.horse_id = p.horse_id
  )
  select c.entity, c.id, c.sync_ts, c.deleted, c.data
  from changes c
  where (c.sync_ts, c.id) > (v_ts, v_id)
  order by c.sync_ts, c.id
  limit v_limit;
end;
$$;

alter function api.sync_sensor_readings(uuid, jsonb) owner to api_writer;
alter function api.sync_changes(timestamptz, uuid, int) owner to api_reader;

revoke all on function api.sync_sensor_readings(uuid, jsonb), api.sync_changes(timestamptz, uuid, int)
  from public, anon, authenticated, service_role;
grant execute on function api.sync_sensor_readings(uuid, jsonb), api.sync_changes(timestamptz, uuid, int)
  to authenticated;
