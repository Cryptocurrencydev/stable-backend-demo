-- =============================================================================
-- 0008 · api write functions
--
-- Pattern for every write:
--   1. app.require_user()                      -> 401 if no JWT
--   2. app.idempotency_begin(key, op, request) -> replay returns stored result
--   3. validate input                          -> 400 with a stable error code
--   4. app.require_permission(...)             -> 404 / 403 via has_permission
--   5. mutate private tables                   -> RLS re-checks as api_writer
--   6. app.enqueue_outbox(...) if needed       -> same transaction
--   7. app.idempotency_finish(key, result)
--
-- All functions are SECURITY DEFINER, owned by api_writer, search_path = ''.
-- =============================================================================

create or replace function app.check_arg(p_ok boolean, p_code text, p_detail text default null)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_ok is not true then
    perform app.raise_error('22023', p_code, coalesce(p_detail, p_code));
  end if;
end;
$$;
revoke all on function app.check_arg(boolean, text, text) from public, anon, authenticated, service_role;
grant execute on function app.check_arg(boolean, text, text) to api_writer, api_reader;

-- Product registration status without revealing who owns a product.
create or replace function app.product_status(p_qr_code text, p_user uuid)
returns table (product_id uuid, status text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id,
         case when p.owner_id is null then 'unregistered'
              when p.owner_id = p_user then 'mine'
              else 'taken' end
  from private.products p
  where p.qr_code = p_qr_code and p.deleted_at is null
$$;
revoke all on function app.product_status(text, uuid) from public, anon, authenticated, service_role;
grant execute on function app.product_status(text, uuid) to api_writer;

-- ---------------------------------------------------------------- stables
create or replace function api.create_stable(
  p_idempotency_key uuid,
  p_name            text,
  p_city            text default null,
  p_country         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.stables;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'create_stable',
    jsonb_build_object('name', p_name, 'city', p_city, 'country', p_country));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(char_length(btrim(p_name)) between 1 and 120, 'invalid_name', 'name must be 1-120 characters');
  perform app.check_arg(p_country is null or p_country ~ '^[A-Z]{2}$', 'invalid_country', 'country must be ISO 3166-1 alpha-2, e.g. DE');

  insert into private.stables (name, city, country, created_by)
  values (btrim(p_name), nullif(btrim(p_city), ''), p_country, v_user)
  returning * into v_row;

  insert into private.memberships (user_id, stable_id, role, granted_by)
  values (v_user, v_row.id, 'owner', v_user);

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'name', v_row.name, 'city', v_row.city, 'country', v_row.country,
    'my_role', 'owner', 'updated_at', v_row.updated_at));
end;
$$;

-- ---------------------------------------------------------------- horses
create or replace function api.create_horse(
  p_idempotency_key uuid,
  p_name            text,
  p_breed           text default null,
  p_birth_year      int  default null,
  p_color           text default null,
  p_stable_id       uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.horses;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'create_horse', jsonb_build_object(
    'name', p_name, 'breed', p_breed, 'birth_year', p_birth_year, 'color', p_color, 'stable_id', p_stable_id));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(char_length(btrim(p_name)) between 1 and 80, 'invalid_name', 'name must be 1-80 characters');
  perform app.check_arg(p_birth_year is null or p_birth_year between 1980 and extract(year from now())::int,
    'invalid_birth_year', 'birth_year must be between 1980 and the current year');
  perform app.check_arg(p_breed is null or char_length(p_breed) <= 80, 'invalid_breed');
  perform app.check_arg(p_color is null or char_length(p_color) <= 40, 'invalid_color');
  if p_stable_id is not null then
    perform app.require_permission('stable', p_stable_id, 'board_horse');
  end if;

  insert into private.horses (name, breed, birth_year, color, stable_id, created_by)
  values (btrim(p_name), p_breed, p_birth_year, p_color, p_stable_id, v_user)
  returning * into v_row;

  insert into private.memberships (user_id, horse_id, role, granted_by)
  values (v_user, v_row.id, 'owner', v_user);

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'name', v_row.name, 'breed', v_row.breed, 'birth_year', v_row.birth_year,
    'color', v_row.color, 'stable_id', v_row.stable_id, 'my_roles', jsonb_build_array('owner'),
    'updated_at', v_row.updated_at));
end;
$$;

create or replace function api.update_horse(
  p_idempotency_key uuid,
  p_horse_id        uuid,
  p_name            text default null,
  p_breed           text default null,
  p_birth_year      int  default null,
  p_color           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cached jsonb;
  v_row    private.horses;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'update_horse', jsonb_build_object(
    'horse_id', p_horse_id, 'name', p_name, 'breed', p_breed, 'birth_year', p_birth_year, 'color', p_color));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(p_horse_id is not null, 'horse_id_required');
  perform app.require_permission('horse', p_horse_id, 'update');
  perform app.check_arg(p_name is null or char_length(btrim(p_name)) between 1 and 80, 'invalid_name');
  perform app.check_arg(p_birth_year is null or p_birth_year between 1980 and extract(year from now())::int, 'invalid_birth_year');

  update private.horses
     set name       = coalesce(btrim(p_name), name),
         breed      = coalesce(p_breed, breed),
         birth_year = coalesce(p_birth_year, birth_year),
         color      = coalesce(p_color, color)
   where id = p_horse_id and deleted_at is null
  returning * into v_row;
  if not found then perform app.raise_error('PT404', 'not_found', 'horse not found'); end if;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'name', v_row.name, 'breed', v_row.breed, 'birth_year', v_row.birth_year,
    'color', v_row.color, 'stable_id', v_row.stable_id, 'updated_at', v_row.updated_at));
end;
$$;

-- Board a horse at a stable (or remove it with p_stable_id = null).
create or replace function api.move_horse(
  p_idempotency_key uuid,
  p_horse_id        uuid,
  p_stable_id       uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cached jsonb;
  v_row    private.horses;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'move_horse',
    jsonb_build_object('horse_id', p_horse_id, 'stable_id', p_stable_id));
  if v_cached is not null then return v_cached; end if;

  perform app.require_permission('horse', p_horse_id, 'update');
  if p_stable_id is not null then
    perform app.require_permission('stable', p_stable_id, 'board_horse');
  end if;

  update private.horses set stable_id = p_stable_id
   where id = p_horse_id and deleted_at is null
  returning * into v_row;
  if not found then perform app.raise_error('PT404', 'not_found', 'horse not found'); end if;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'stable_id', v_row.stable_id, 'updated_at', v_row.updated_at));
end;
$$;

create or replace function api.delete_horse(p_idempotency_key uuid, p_horse_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cached jsonb;
  v_row    private.horses;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'delete_horse', jsonb_build_object('horse_id', p_horse_id));
  if v_cached is not null then return v_cached; end if;

  perform app.require_permission('horse', p_horse_id, 'delete');

  update private.horses set deleted_at = clock_timestamp()
   where id = p_horse_id and deleted_at is null
  returning * into v_row;
  if not found then perform app.raise_error('PT404', 'not_found', 'horse not found'); end if;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'deleted', true, 'updated_at', v_row.updated_at));
end;
$$;

-- ---------------------------------------------------------------- memberships
create or replace function api.grant_membership(
  p_idempotency_key uuid,
  p_resource_type   text,
  p_resource_id     uuid,
  p_user_id         uuid,
  p_role            text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user     uuid := app.require_user();
  v_cached   jsonb;
  v_existing private.memberships;
  v_row      private.memberships;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'grant_membership', jsonb_build_object(
    'resource_type', p_resource_type, 'resource_id', p_resource_id, 'user_id', p_user_id, 'role', p_role));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(p_resource_type in ('horse', 'stable'), 'invalid_resource_type', 'resource_type must be horse or stable');
  perform app.check_arg(p_user_id is not null, 'user_id_required');
  perform app.check_arg(
    (p_resource_type = 'horse'  and p_role in ('owner', 'trainer', 'rider', 'viewer')) or
    (p_resource_type = 'stable' and p_role in ('owner', 'stable_manager', 'trainer', 'rider', 'viewer')),
    'invalid_role', format('role %s is not valid for %s', p_role, p_resource_type));

  perform app.require_permission(p_resource_type, p_resource_id, 'manage_members');
  if p_role = 'owner' then
    perform app.require_permission(p_resource_type, p_resource_id, 'manage_owners');
  end if;

  select * into v_existing from private.memberships m
   where m.user_id = p_user_id and m.revoked_at is null
     and ((p_resource_type = 'horse' and m.horse_id = p_resource_id)
       or (p_resource_type = 'stable' and m.stable_id = p_resource_id));

  if found and v_existing.role = p_role then
    v_row := v_existing;
  else
    if found then
      if v_existing.role = 'owner' and not app.has_permission(v_user, p_resource_type, p_resource_id, 'manage_owners') then
        perform app.raise_error('42501', 'forbidden', 'Only owners can change an owner''s role');
      end if;
      if v_existing.role = 'owner' and (select count(*) from private.memberships m
            where m.revoked_at is null and m.role = 'owner'
              and ((p_resource_type = 'horse' and m.horse_id = p_resource_id)
                or (p_resource_type = 'stable' and m.stable_id = p_resource_id))) = 1 then
        perform app.raise_error('PT409', 'last_owner', 'A resource must keep at least one owner');
      end if;
      update private.memberships set revoked_at = clock_timestamp() where id = v_existing.id;
    end if;

    begin
      insert into private.memberships (user_id, horse_id, stable_id, role, granted_by)
      values (p_user_id,
              case when p_resource_type = 'horse'  then p_resource_id end,
              case when p_resource_type = 'stable' then p_resource_id end,
              p_role, v_user)
      returning * into v_row;
    exception when foreign_key_violation then
      perform app.raise_error('PT404', 'user_not_found', 'No such user');
    end;
  end if;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'user_id', v_row.user_id, 'resource_type', p_resource_type,
    'resource_id', p_resource_id, 'role', v_row.role, 'updated_at', v_row.updated_at));
end;
$$;

create or replace function api.revoke_membership(p_idempotency_key uuid, p_membership_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_m      private.memberships;
  v_type   text;
  v_res    uuid;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'revoke_membership', jsonb_build_object('membership_id', p_membership_id));
  if v_cached is not null then return v_cached; end if;

  select * into v_m from private.memberships where id = p_membership_id and revoked_at is null;
  if not found then perform app.raise_error('PT404', 'not_found', 'membership not found'); end if;

  v_type := case when v_m.horse_id is not null then 'horse' else 'stable' end;
  v_res  := coalesce(v_m.horse_id, v_m.stable_id);

  if v_m.user_id <> v_user then
    perform app.require_permission(v_type, v_res, 'manage_members');
    if v_m.role = 'owner' then
      perform app.require_permission(v_type, v_res, 'manage_owners');
    end if;
  end if;

  if v_m.role = 'owner' and (select count(*) from private.memberships m
        where m.revoked_at is null and m.role = 'owner'
          and (m.horse_id = v_res or m.stable_id = v_res)) = 1 then
    perform app.raise_error('PT409', 'last_owner', 'A resource must keep at least one owner');
  end if;

  update private.memberships set revoked_at = clock_timestamp() where id = v_m.id
  returning * into v_m;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_m.id, 'revoked', true, 'updated_at', v_m.updated_at));
end;
$$;

-- ---------------------------------------------------------------- stable tasks
create or replace function api.create_stable_task(
  p_idempotency_key uuid,
  p_stable_id       uuid,
  p_title           text,
  p_details         text        default null,
  p_due_at          timestamptz default null,
  p_horse_id        uuid        default null,
  p_assigned_to     uuid        default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.stable_tasks;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'create_stable_task', jsonb_build_object(
    'stable_id', p_stable_id, 'title', p_title, 'details', p_details, 'due_at', p_due_at,
    'horse_id', p_horse_id, 'assigned_to', p_assigned_to));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(char_length(btrim(p_title)) between 1 and 200, 'invalid_title', 'title must be 1-200 characters');
  perform app.check_arg(p_details is null or char_length(p_details) <= 2000, 'invalid_details');
  perform app.require_permission('stable', p_stable_id, 'manage_tasks');

  if p_horse_id is not null and not exists (
       select 1 from private.horses h where h.id = p_horse_id and h.stable_id = p_stable_id and h.deleted_at is null) then
    perform app.raise_error('22023', 'horse_not_in_stable', 'horse_id must belong to this stable');
  end if;
  if p_assigned_to is not null and not exists (
       select 1 from private.memberships m
        where m.stable_id = p_stable_id and m.user_id = p_assigned_to and m.revoked_at is null) then
    perform app.raise_error('22023', 'assignee_not_member', 'assigned_to must be a member of this stable');
  end if;

  insert into private.stable_tasks (stable_id, horse_id, title, details, due_at, assigned_to, created_by)
  values (p_stable_id, p_horse_id, btrim(p_title), p_details, p_due_at, p_assigned_to, v_user)
  returning * into v_row;

  if p_assigned_to is not null then
    perform app.enqueue_outbox('task.assigned', 'stable_task', v_row.id, jsonb_build_object(
      'task_id', v_row.id, 'stable_id', v_row.stable_id, 'assigned_to', v_row.assigned_to,
      'title', v_row.title, 'due_at', v_row.due_at));
  end if;

  return app.idempotency_finish(p_idempotency_key, to_jsonb(v_row) - 'deleted_at');
end;
$$;

create or replace function api.complete_stable_task(p_idempotency_key uuid, p_task_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.stable_tasks;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'complete_stable_task', jsonb_build_object('task_id', p_task_id));
  if v_cached is not null then return v_cached; end if;

  perform app.require_permission('stable_task', p_task_id, 'complete');

  update private.stable_tasks
     set status = 'done', completed_by = v_user, completed_at = clock_timestamp()
   where id = p_task_id and deleted_at is null and status = 'open'
  returning * into v_row;

  if found then
    perform app.enqueue_outbox('task.completed', 'stable_task', v_row.id, jsonb_build_object(
      'task_id', v_row.id, 'stable_id', v_row.stable_id, 'completed_by', v_user, 'title', v_row.title));
  else
    -- already done (e.g. by a colleague): converge instead of failing
    select * into v_row from private.stable_tasks where id = p_task_id and deleted_at is null;
    if not found then perform app.raise_error('PT404', 'not_found', 'task not found'); end if;
  end if;

  return app.idempotency_finish(p_idempotency_key, to_jsonb(v_row) - 'deleted_at');
end;
$$;

-- ---------------------------------------------------------------- training logs
create or replace function api.log_training(
  p_idempotency_key  uuid,
  p_horse_id         uuid,
  p_started_at       timestamptz,
  p_duration_minutes int,
  p_discipline       text,
  p_intensity        text default 'moderate',
  p_notes            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.training_logs;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'log_training', jsonb_build_object(
    'horse_id', p_horse_id, 'started_at', p_started_at, 'duration_minutes', p_duration_minutes,
    'discipline', p_discipline, 'intensity', p_intensity, 'notes', p_notes));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(p_horse_id is not null, 'horse_id_required');
  perform app.check_arg(p_started_at is not null and p_started_at <= now() + interval '5 minutes'
                        and p_started_at >= now() - interval '2 years',
    'invalid_started_at', 'started_at must be within the last 2 years and not in the future');
  perform app.check_arg(p_duration_minutes between 1 and 600, 'invalid_duration', 'duration_minutes must be 1-600');
  perform app.check_arg(p_discipline in ('dressage', 'jumping', 'eventing', 'endurance', 'western', 'groundwork', 'hacking', 'lunging', 'other'),
    'invalid_discipline');
  perform app.check_arg(coalesce(p_intensity, 'moderate') in ('light', 'moderate', 'hard'), 'invalid_intensity');
  perform app.check_arg(p_notes is null or char_length(p_notes) <= 4000, 'invalid_notes');

  perform app.require_permission('horse', p_horse_id, 'log_training');
  if exists (select 1 from private.horses where id = p_horse_id and deleted_at is not null) then
    perform app.raise_error('PT404', 'not_found', 'horse not found');
  end if;

  insert into private.training_logs (horse_id, author_id, started_at, duration_minutes, discipline, intensity, notes)
  values (p_horse_id, v_user, p_started_at, p_duration_minutes, p_discipline, coalesce(p_intensity, 'moderate'), p_notes)
  returning * into v_row;

  return app.idempotency_finish(p_idempotency_key, to_jsonb(v_row) - 'deleted_at');
end;
$$;

create or replace function api.delete_training_log(p_idempotency_key uuid, p_log_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cached jsonb;
  v_row    private.training_logs;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'delete_training_log', jsonb_build_object('log_id', p_log_id));
  if v_cached is not null then return v_cached; end if;

  perform app.require_permission('training_log', p_log_id, 'delete');

  update private.training_logs set deleted_at = clock_timestamp()
   where id = p_log_id and deleted_at is null
  returning * into v_row;
  if not found then perform app.raise_error('PT404', 'not_found', 'training log not found'); end if;

  return app.idempotency_finish(p_idempotency_key, jsonb_build_object(
    'id', v_row.id, 'deleted', true, 'updated_at', v_row.updated_at));
end;
$$;

-- ---------------------------------------------------------------- products (QR registration)
create or replace function api.register_product(
  p_idempotency_key uuid,
  p_qr_code         text,
  p_horse_id        uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_qr     text := upper(btrim(p_qr_code));
  v_status record;
  v_row    private.products;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'register_product',
    jsonb_build_object('qr_code', v_qr, 'horse_id', p_horse_id));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(v_qr ~ '^[A-Z0-9-]{8,64}$', 'invalid_qr_code', 'qr_code must be 8-64 chars of A-Z, 0-9 or -');

  select * into v_status from app.product_status(v_qr, v_user);
  if not found then
    perform app.raise_error('PT404', 'product_not_found', 'No product with this QR code');
  elsif v_status.status = 'taken' then
    perform app.raise_error('PT409', 'product_already_registered', 'This product is registered to another account');
  end if;

  if p_horse_id is not null then
    perform app.require_permission('horse', p_horse_id, 'update');
  end if;

  update private.products
     set owner_id = v_user,
         horse_id = p_horse_id,
         registered_at = coalesce(registered_at, clock_timestamp())
   where id = v_status.product_id
  returning * into v_row;

  if v_status.status = 'unregistered' then
    perform app.enqueue_outbox('product.registered', 'product', v_row.id, jsonb_build_object(
      'product_id', v_row.id, 'qr_code', v_row.qr_code, 'gtin', v_row.gtin,
      'manufacturer', v_row.manufacturer, 'registered_at', v_row.registered_at));
  end if;

  return app.idempotency_finish(p_idempotency_key, to_jsonb(v_row) - 'deleted_at' - 'created_at');
end;
$$;

-- Public Digital Product Passport lookup by QR code. Callable by anon: returns
-- only manufacturer data, never owner or horse.
create or replace function api.product_passport(p_qr_code text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'qr_code', p.qr_code, 'gtin', p.gtin, 'name', p.name, 'manufacturer', p.manufacturer,
    'category', p.category, 'passport', p.passport, 'is_registered', p.owner_id is not null)
  from private.products p
  where p.qr_code = upper(btrim(p_qr_code)) and p.deleted_at is null
$$;

-- ---------------------------------------------------------------- sensors
create or replace function api.register_sensor(
  p_idempotency_key uuid,
  p_horse_id        uuid,
  p_device_id       text,
  p_label           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user   uuid := app.require_user();
  v_cached jsonb;
  v_row    private.sensors;
begin
  v_cached := app.idempotency_begin(p_idempotency_key, 'register_sensor',
    jsonb_build_object('horse_id', p_horse_id, 'device_id', p_device_id, 'label', p_label));
  if v_cached is not null then return v_cached; end if;

  perform app.check_arg(p_device_id ~ '^[A-Za-z0-9:_-]{4,64}$', 'invalid_device_id');
  perform app.check_arg(p_label is null or char_length(p_label) <= 80, 'invalid_label');
  perform app.require_permission('horse', p_horse_id, 'manage_sensors');

  begin
    insert into private.sensors (horse_id, device_id, label, created_by)
    values (p_horse_id, p_device_id, p_label, v_user)
    returning * into v_row;
  exception when unique_violation then
    perform app.raise_error('PT409', 'device_already_registered', 'This device is already registered');
  end;

  return app.idempotency_finish(p_idempotency_key, to_jsonb(v_row) - 'deleted_at');
end;
$$;

-- ---------------------------------------------------------------- permissions introspection
create or replace function api.my_permissions(p_resource_type text, p_resource_id uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(a.action order by a.action), '{}')
  from (select distinct rp.action from private.role_permissions rp where rp.resource_type = p_resource_type) a
  where app.has_permission(app.uid(), p_resource_type, p_resource_id, a.action)
$$;

-- ---------------------------------------------------------------- ownership + grants
alter function api.create_stable(uuid, text, text, text)                                  owner to api_writer;
alter function api.create_horse(uuid, text, text, int, text, uuid)                        owner to api_writer;
alter function api.update_horse(uuid, uuid, text, text, int, text)                        owner to api_writer;
alter function api.move_horse(uuid, uuid, uuid)                                           owner to api_writer;
alter function api.delete_horse(uuid, uuid)                                               owner to api_writer;
alter function api.grant_membership(uuid, text, uuid, uuid, text)                         owner to api_writer;
alter function api.revoke_membership(uuid, uuid)                                          owner to api_writer;
alter function api.create_stable_task(uuid, uuid, text, text, timestamptz, uuid, uuid)    owner to api_writer;
alter function api.complete_stable_task(uuid, uuid)                                       owner to api_writer;
alter function api.log_training(uuid, uuid, timestamptz, int, text, text, text)           owner to api_writer;
alter function api.delete_training_log(uuid, uuid)                                        owner to api_writer;
alter function api.register_product(uuid, text, uuid)                                     owner to api_writer;
alter function api.register_sensor(uuid, uuid, text, text)                                owner to api_writer;
alter function api.my_permissions(text, uuid)                                             owner to api_reader;
-- product_passport stays owned by the migration role: it must read unregistered
-- products for anonymous scanners, and exposes manufacturer data only.

revoke all on all functions in schema api from public, anon, authenticated, service_role;
grant execute on function
  api.create_stable(uuid, text, text, text),
  api.create_horse(uuid, text, text, int, text, uuid),
  api.update_horse(uuid, uuid, text, text, int, text),
  api.move_horse(uuid, uuid, uuid),
  api.delete_horse(uuid, uuid),
  api.grant_membership(uuid, text, uuid, uuid, text),
  api.revoke_membership(uuid, uuid),
  api.create_stable_task(uuid, uuid, text, text, timestamptz, uuid, uuid),
  api.complete_stable_task(uuid, uuid),
  api.log_training(uuid, uuid, timestamptz, int, text, text, text),
  api.delete_training_log(uuid, uuid),
  api.register_product(uuid, text, uuid),
  api.register_sensor(uuid, uuid, text, text),
  api.my_permissions(text, uuid)
to authenticated;
grant execute on function api.product_passport(text) to anon, authenticated;
