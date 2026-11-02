-- =============================================================================
-- 0004 · Permission engine
--
-- ONE central check:  app.has_permission(user, resource_type, resource_id, action)
--
-- Every RLS policy and every api write function calls it. Rules are data, in
-- private.role_permissions, so changing "what a trainer may do" is a one-row
-- migration, not a code hunt.
--
-- Context-based: permissions come from memberships on a specific resource, so
-- the same user can be owner of horse A, trainer of horse B and a stranger to
-- horse C. Inheritance: an owner or stable_manager of a stable acts as
-- 'stable_manager' on every horse whose stable_id is that stable.
--
-- Child resources resolve to their parent:
--   training_log -> horse,  stable_task -> stable,  sensor -> horse,
--   product      -> owner_id, or the linked horse (read only)
-- =============================================================================

create table private.role_permissions (
  resource_type  text not null check (resource_type in ('horse', 'stable')),
  role           text not null check (role in ('owner', 'trainer', 'rider', 'stable_manager', 'viewer')),
  action         text not null,
  primary key (resource_type, role, action)
);

insert into private.role_permissions (resource_type, role, action)
select 'horse', r.role, a.action
from (values
  -- action               owner trainer rider  mgr    viewer
  ('read',                true, true,   true,  true,  true),
  ('update',              true, false,  false, false, false),
  ('delete',              true, false,  false, false, false),
  ('manage_members',      true, false,  false, false, false),
  ('manage_owners',       true, false,  false, false, false),
  ('read_training',       true, true,   true,  true,  false),
  ('log_training',        true, true,   true,  false, false),
  ('manage_training',     true, false,  false, false, false),
  ('manage_sensors',      true, false,  false, true,  false),
  ('read_sensor_data',    true, true,   false, true,  false),
  ('write_sensor_data',   true, true,   false, true,  false),
  ('read_media',          true, true,   true,  true,  true),
  ('write_media',         true, true,   false, true,  false)
) as a(action, owner, trainer, rider, mgr, viewer)
cross join lateral (values
  ('owner', a.owner), ('trainer', a.trainer), ('rider', a.rider), ('stable_manager', a.mgr), ('viewer', a.viewer)
) as r(role, allowed)
where r.allowed;

insert into private.role_permissions (resource_type, role, action)
select 'stable', r.role, a.action
from (values
  -- action               owner mgr    trainer rider  viewer
  ('read',                true, true,  true,   true,  true),
  ('update',              true, true,  false,  false, false),
  ('delete',              true, false, false,  false, false),
  ('manage_members',      true, true,  false,  false, false),
  ('manage_owners',       true, false, false,  false, false),
  ('read_tasks',          true, true,  true,   true,  false),
  ('manage_tasks',        true, true,  false,  false, false),
  ('complete_task',       true, true,  true,   true,  false),
  ('board_horse',         true, true,  true,   true,  false)
) as a(action, owner, mgr, trainer, rider, viewer)
cross join lateral (values
  ('owner', a.owner), ('stable_manager', a.mgr), ('trainer', a.trainer), ('rider', a.rider), ('viewer', a.viewer)
) as r(role, allowed)
where r.allowed;

-- -----------------------------------------------------------------------------
-- Current user from the PostgREST JWT claims. Reads the GUC directly so the
-- owner roles don't need USAGE on the auth schema.
-- -----------------------------------------------------------------------------
create or replace function app.uid()
returns uuid
language sql
stable
set search_path = ''
as $$
  select nullif(
    coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub'
    ), ''
  )::uuid
$$;

-- -----------------------------------------------------------------------------
-- Client roles reach these functions only implicitly (Postgres checks EXECUTE
-- on functions in view bodies and RLS policy expressions as the CALLING role).
-- Guard: anon/authenticated may only ask about THEMSELVES, so nobody can probe
-- another user's permissions. Owner roles and migrations are unrestricted.
-- -----------------------------------------------------------------------------
create or replace function app.is_untrusted_probe(p_user uuid)
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce(current_setting('role', true), 'none') in ('anon', 'authenticated')
         and p_user is distinct from app.uid()
$$;

-- -----------------------------------------------------------------------------
-- Effective roles of a user on a horse (direct + inherited from the stable).
-- -----------------------------------------------------------------------------
create or replace function app.horse_roles(p_user uuid, p_horse uuid)
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select m.role
  from private.memberships m
  where m.user_id = p_user and m.horse_id = p_horse and m.revoked_at is null
    and not app.is_untrusted_probe(p_user)
  union
  select 'stable_manager'
  from private.horses h
  join private.memberships m
    on m.stable_id = h.stable_id and m.user_id = p_user and m.revoked_at is null
  where h.id = p_horse
    and m.role in ('owner', 'stable_manager')
    and not app.is_untrusted_probe(p_user)
$$;

-- -----------------------------------------------------------------------------
-- THE central permission check.
-- -----------------------------------------------------------------------------
create or replace function app.has_permission(
  p_user           uuid,
  p_resource_type  text,
  p_resource_id    uuid,
  p_action         text
)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_parent  uuid;
  v_owner   uuid;
  v_author  uuid;
begin
  if p_user is null or p_resource_id is null or p_action is null
     or app.is_untrusted_probe(p_user) then
    return false;
  end if;

  case p_resource_type
    when 'horse' then
      return exists (
        select 1
        from app.horse_roles(p_user, p_resource_id) r(role)
        join private.role_permissions rp
          on rp.resource_type = 'horse' and rp.role = r.role and rp.action = p_action
      );

    when 'stable' then
      return exists (
        select 1
        from private.memberships m
        join private.role_permissions rp
          on rp.resource_type = 'stable' and rp.role = m.role and rp.action = p_action
        where m.user_id = p_user and m.stable_id = p_resource_id and m.revoked_at is null
      );

    when 'training_log' then
      select t.horse_id, t.author_id into v_parent, v_author
      from private.training_logs t where t.id = p_resource_id;
      if not found then return false; end if;
      return case p_action
        when 'read'   then app.has_permission(p_user, 'horse', v_parent, 'read_training')
        when 'delete' then (v_author = p_user and app.has_permission(p_user, 'horse', v_parent, 'log_training'))
                           or app.has_permission(p_user, 'horse', v_parent, 'manage_training')
        else false
      end;

    when 'stable_task' then
      select t.stable_id into v_parent from private.stable_tasks t where t.id = p_resource_id;
      if not found then return false; end if;
      return case p_action
        when 'read'     then app.has_permission(p_user, 'stable', v_parent, 'read_tasks')
        when 'complete' then app.has_permission(p_user, 'stable', v_parent, 'complete_task')
        when 'update'   then app.has_permission(p_user, 'stable', v_parent, 'manage_tasks')
        when 'delete'   then app.has_permission(p_user, 'stable', v_parent, 'manage_tasks')
        else false
      end;

    when 'sensor' then
      select s.horse_id into v_parent from private.sensors s where s.id = p_resource_id;
      if not found then return false; end if;
      return case p_action
        when 'read'        then app.has_permission(p_user, 'horse', v_parent, 'read_sensor_data')
        when 'write_data'  then app.has_permission(p_user, 'horse', v_parent, 'write_sensor_data')
        when 'manage'      then app.has_permission(p_user, 'horse', v_parent, 'manage_sensors')
        else false
      end;

    when 'product' then
      select p.owner_id, p.horse_id into v_owner, v_parent from private.products p where p.id = p_resource_id;
      if not found then return false; end if;
      if v_owner = p_user then
        return p_action in ('read', 'update');
      end if;
      return p_action = 'read' and v_parent is not null
             and app.has_permission(p_user, 'horse', v_parent, 'read');

    else
      return false;
  end case;
end;
$$;

comment on function app.has_permission(uuid, text, uuid, text) is
  'Single source of truth for authorization. Used by every RLS policy and api write function.';

-- Raise helpers with stable error codes. PostgREST maps:
--   42501 -> 403, PT404 -> 404, PT409 -> 409, 22023 -> 400, 28000 -> 401
create or replace function app.raise_error(p_sqlstate text, p_code text, p_detail text default null)
returns void
language plpgsql
set search_path = ''
as $$
begin
  raise exception using errcode = p_sqlstate, message = p_code, detail = coalesce(p_detail, p_code);
end;
$$;

create or replace function app.require_user()
returns uuid
language plpgsql
stable
set search_path = ''
as $$
declare v uuid := app.uid();
begin
  if v is null then
    perform app.raise_error('28000', 'unauthenticated', 'A signed-in user is required');
  end if;
  return v;
end;
$$;

-- Not readable -> 404 (don't leak existence). Readable but not allowed -> 403.
create or replace function app.require_permission(p_resource_type text, p_resource_id uuid, p_action text)
returns void
language plpgsql
stable
set search_path = ''
as $$
declare
  v_user uuid := app.require_user();
begin
  if app.has_permission(v_user, p_resource_type, p_resource_id, p_action) then
    return;
  end if;
  if p_action <> 'read' and app.has_permission(v_user, p_resource_type, p_resource_id, 'read') then
    perform app.raise_error('42501', 'forbidden',
      format('Missing permission %s on %s', p_action, p_resource_type));
  end if;
  perform app.raise_error('PT404', 'not_found', format('%s not found', p_resource_type));
end;
$$;

-- Can p_user create a membership with p_role on the resource?
--  * manage_members is required; granting 'owner' additionally needs manage_owners
--  * bootstrap: the creator of a resource with no active members may make
--    themselves owner (used by create_horse / create_stable in the same txn)
create or replace function app.can_grant_membership(p_user uuid, p_resource_type text, p_resource_id uuid, p_member uuid, p_role text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if p_user is null then return false; end if;

  if p_role = 'owner' and p_member = p_user and not exists (
       select 1 from private.memberships m
       where m.revoked_at is null
         and ((p_resource_type = 'horse' and m.horse_id = p_resource_id)
           or (p_resource_type = 'stable' and m.stable_id = p_resource_id)))
     and (
       (p_resource_type = 'horse'  and exists (select 1 from private.horses  h where h.id = p_resource_id and h.created_by = p_user))
       or (p_resource_type = 'stable' and exists (select 1 from private.stables s where s.id = p_resource_id and s.created_by = p_user))
     ) then
    return true;
  end if;

  if not app.has_permission(p_user, p_resource_type, p_resource_id, 'manage_members') then
    return false;
  end if;
  if p_role = 'owner' then
    return app.has_permission(p_user, p_resource_type, p_resource_id, 'manage_owners');
  end if;
  return true;
end;
$$;

-- -----------------------------------------------------------------------------
-- Grants: only the owner roles may call the engine. Client roles cannot call
-- has_permission with an arbitrary user id.
-- -----------------------------------------------------------------------------
revoke all on all functions in schema app from public, anon, authenticated, service_role;
grant execute on function
  app.uid(),
  app.is_untrusted_probe(uuid),
  app.horse_roles(uuid, uuid),
  app.has_permission(uuid, text, uuid, text),
  app.raise_error(text, text, text),
  app.require_user(),
  app.require_permission(text, uuid, text),
  app.can_grant_membership(uuid, text, uuid, uuid, text),
  app.touch_updated_at()
to api_reader, api_writer;

-- See app.is_untrusted_probe: needed because view bodies and RLS policies
-- evaluate function EXECUTE privileges as the calling role.
grant usage on schema app to authenticated;
grant execute on function app.uid(), app.is_untrusted_probe(uuid), app.horse_roles(uuid, uuid),
  app.has_permission(uuid, text, uuid, text) to authenticated;
