-- =============================================================================
-- 0002 · Core tables (private schema)
--
-- Conventions
--   * uuid primary keys (gen_random_uuid) so mobile clients can reason about ids
--   * created_at / updated_at on every syncable table; updated_at is maintained
--     by trigger with clock_timestamp() so it strictly advances inside a txn
--   * soft deletes via deleted_at (horses, stables, tasks, logs, products,
--     sensors) and revoked_at (memberships) so offline clients receive tombstones
-- =============================================================================

create or replace function app.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := clock_timestamp();
  if tg_op = 'INSERT' then
    new.created_at := coalesce(new.created_at, new.updated_at);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------- stables
create table private.stables (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 120),
  city        text check (char_length(city) <= 120),
  country     text check (country ~ '^[A-Z]{2}$'),
  created_by  uuid not null references auth.users (id),
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  deleted_at  timestamptz
);

-- ---------------------------------------------------------------- horses
create table private.horses (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 80),
  breed       text check (char_length(breed) <= 80),
  birth_year  int check (birth_year between 1980 and 2100),
  color       text check (char_length(color) <= 40),
  stable_id   uuid references private.stables (id),
  created_by  uuid not null references auth.users (id),
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  deleted_at  timestamptz
);
create index horses_stable_id_idx on private.horses (stable_id) where stable_id is not null;

-- ---------------------------------------------------------------- memberships
-- user x (horse | stable) with a role. Exactly one of horse_id / stable_id.
create table private.memberships (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id),
  horse_id     uuid references private.horses (id),
  stable_id    uuid references private.stables (id),
  role         text not null check (role in ('owner', 'trainer', 'rider', 'stable_manager', 'viewer')),
  granted_by   uuid references auth.users (id),
  created_at   timestamptz not null default clock_timestamp(),
  updated_at   timestamptz not null default clock_timestamp(),
  revoked_at   timestamptz,
  constraint memberships_one_resource check (num_nonnulls(horse_id, stable_id) = 1),
  -- stable_manager only makes sense on a stable
  constraint memberships_role_scope check (horse_id is null or role <> 'stable_manager')
);
-- one active role per user per resource
create unique index memberships_active_horse_uq on private.memberships (user_id, horse_id) where horse_id is not null and revoked_at is null;
create unique index memberships_active_stable_uq on private.memberships (user_id, stable_id) where stable_id is not null and revoked_at is null;
create index memberships_horse_idx on private.memberships (horse_id) where horse_id is not null;
create index memberships_stable_idx on private.memberships (stable_id) where stable_id is not null;
create index memberships_user_idx on private.memberships (user_id, updated_at);

-- ---------------------------------------------------------------- stable tasks
create table private.stable_tasks (
  id            uuid primary key default gen_random_uuid(),
  stable_id     uuid not null references private.stables (id),
  horse_id      uuid references private.horses (id),
  title         text not null check (char_length(title) between 1 and 200),
  details       text check (char_length(details) <= 2000),
  due_at        timestamptz,
  assigned_to   uuid references auth.users (id),
  status        text not null default 'open' check (status in ('open', 'done')),
  completed_by  uuid references auth.users (id),
  completed_at  timestamptz,
  created_by    uuid not null references auth.users (id),
  created_at    timestamptz not null default clock_timestamp(),
  updated_at    timestamptz not null default clock_timestamp(),
  deleted_at    timestamptz,
  constraint stable_tasks_done_consistency check ((status = 'done') = (completed_at is not null))
);
create index stable_tasks_stable_idx on private.stable_tasks (stable_id, status);

-- ---------------------------------------------------------------- training logs
create table private.training_logs (
  id                uuid primary key default gen_random_uuid(),
  horse_id          uuid not null references private.horses (id),
  author_id         uuid not null references auth.users (id),
  started_at        timestamptz not null,
  duration_minutes  int not null check (duration_minutes between 1 and 600),
  discipline        text not null check (discipline in ('dressage', 'jumping', 'eventing', 'endurance', 'western', 'groundwork', 'hacking', 'lunging', 'other')),
  intensity         text not null default 'moderate' check (intensity in ('light', 'moderate', 'hard')),
  notes             text check (char_length(notes) <= 4000),
  created_at        timestamptz not null default clock_timestamp(),
  updated_at        timestamptz not null default clock_timestamp(),
  deleted_at        timestamptz
);
create index training_logs_horse_idx on private.training_logs (horse_id, started_at desc);

-- ---------------------------------------------------------------- products (QR + digital product passport)
-- Rows are created by the manufacturer feed (service role); a rider registers
-- a physical item by scanning its QR code, which sets owner_id.
create table private.products (
  id                 uuid primary key default gen_random_uuid(),
  qr_code            text not null unique check (qr_code ~ '^[A-Z0-9-]{8,64}$'),
  gtin               text check (gtin ~ '^[0-9]{8,14}$'),
  name               text not null check (char_length(name) between 1 and 160),
  manufacturer       text not null check (char_length(manufacturer) between 1 and 160),
  category           text not null check (category in ('saddle', 'bridle', 'blanket', 'boots', 'helmet', 'feed', 'sensor', 'other')),
  -- simple Digital Product Passport record (ESPR-style subset)
  passport           jsonb not null default '{}'::jsonb check (jsonb_typeof(passport) = 'object'),
  owner_id           uuid references auth.users (id),
  horse_id           uuid references private.horses (id),
  registered_at      timestamptz,
  created_at         timestamptz not null default clock_timestamp(),
  updated_at         timestamptz not null default clock_timestamp(),
  deleted_at         timestamptz,
  constraint products_registration_consistency check ((owner_id is null) = (registered_at is null))
);
create index products_owner_idx on private.products (owner_id) where owner_id is not null;
create index products_horse_idx on private.products (horse_id) where horse_id is not null;

-- ---------------------------------------------------------------- sensors + readings (time series)
create table private.sensors (
  id          uuid primary key default gen_random_uuid(),
  horse_id    uuid not null references private.horses (id),
  device_id   text not null unique check (device_id ~ '^[A-Za-z0-9:_-]{4,64}$'),
  label       text check (char_length(label) <= 80),
  created_by  uuid not null references auth.users (id),
  created_at  timestamptz not null default clock_timestamp(),
  updated_at  timestamptz not null default clock_timestamp(),
  deleted_at  timestamptz
);
create index sensors_horse_idx on private.sensors (horse_id);

create table private.sensor_readings (
  id             bigint generated always as identity primary key,
  sensor_id      uuid not null references private.sensors (id),
  device_id      text not null,
  recorded_at    timestamptz not null,
  temperature_c  numeric(5, 2) check (temperature_c between -50 and 80),
  humidity_pct   numeric(5, 2) check (humidity_pct between 0 and 100),
  received_at    timestamptz not null default now(),
  constraint sensor_readings_has_value check (num_nonnulls(temperature_c, humidity_pct) >= 1),
  -- natural idempotency key for offline batch uploads
  constraint sensor_readings_device_time_uq unique (device_id, recorded_at)
);
-- range scans per sensor, and a cheap BRIN for time-window scans on a huge append-only table
create index sensor_readings_sensor_time_idx on private.sensor_readings (sensor_id, recorded_at desc);
create index sensor_readings_recorded_brin on private.sensor_readings using brin (recorded_at);

-- ---------------------------------------------------------------- delta-sync cursors
create index stables_sync_idx       on private.stables (updated_at, id);
create index horses_sync_idx        on private.horses (updated_at, id);
create index stable_tasks_sync_idx  on private.stable_tasks (updated_at, id);
create index training_logs_sync_idx on private.training_logs (updated_at, id);
create index products_sync_idx      on private.products (updated_at, id);
create index sensors_sync_idx       on private.sensors (updated_at, id);

-- ---------------------------------------------------------------- updated_at triggers
do $$
declare t text;
begin
  foreach t in array array['stables', 'horses', 'memberships', 'stable_tasks', 'training_logs', 'products', 'sensors']
  loop
    execute format('create trigger touch_updated_at before insert or update on private.%I for each row execute function app.touch_updated_at()', t);
  end loop;
end $$;
