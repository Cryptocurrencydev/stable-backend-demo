-- =============================================================================
-- 0007 · api schema: read-only views
--
-- Every view is owned by api_reader (SELECT-only, NOBYPASSRLS). Views run with
-- the owner's privileges, so RLS on the private tables is evaluated for
-- api_reader with the caller's JWT (app.uid()). authenticated gets SELECT on the
-- views and nothing else, so even auto-updatable views reject writes.
-- Soft-deleted rows are hidden here; they only appear as tombstones in
-- api.sync_changes.
-- =============================================================================

create or replace view api.stables with (security_barrier = true) as
select s.id, s.name, s.city, s.country, s.created_at, s.updated_at,
       (select m.role from private.memberships m
         where m.stable_id = s.id and m.user_id = app.uid() and m.revoked_at is null) as my_role
from private.stables s
where s.deleted_at is null;

create or replace view api.horses with (security_barrier = true) as
select h.id, h.name, h.breed, h.birth_year, h.color, h.stable_id, h.created_at, h.updated_at,
       array(select r from app.horse_roles(app.uid(), h.id) r order by r) as my_roles
from private.horses h
where h.deleted_at is null;

create or replace view api.memberships with (security_barrier = true) as
select m.id, m.user_id,
       case when m.horse_id is not null then 'horse' else 'stable' end as resource_type,
       coalesce(m.horse_id, m.stable_id) as resource_id,
       m.role, m.granted_by, m.created_at, m.updated_at
from private.memberships m
where m.revoked_at is null;

create or replace view api.stable_tasks with (security_barrier = true) as
select t.id, t.stable_id, t.horse_id, t.title, t.details, t.due_at, t.assigned_to, t.status,
       t.completed_by, t.completed_at, t.created_by, t.created_at, t.updated_at
from private.stable_tasks t
where t.deleted_at is null;

create or replace view api.training_logs with (security_barrier = true) as
select t.id, t.horse_id, t.author_id, t.started_at, t.duration_minutes, t.discipline, t.intensity,
       t.notes, t.created_at, t.updated_at
from private.training_logs t
where t.deleted_at is null;

create or replace view api.products with (security_barrier = true) as
select p.id, p.qr_code, p.gtin, p.name, p.manufacturer, p.category, p.passport,
       p.owner_id, p.horse_id, p.registered_at, p.updated_at
from private.products p
where p.deleted_at is null;

create or replace view api.sensors with (security_barrier = true) as
select s.id, s.horse_id, s.device_id, s.label, s.created_at, s.updated_at
from private.sensors s
where s.deleted_at is null;

create or replace view api.sensor_readings with (security_barrier = true) as
select r.id, r.sensor_id, r.device_id, r.recorded_at, r.temperature_c, r.humidity_pct, r.received_at
from private.sensor_readings r;

do $$
declare v text;
begin
  foreach v in array array['stables', 'horses', 'memberships', 'stable_tasks', 'training_logs', 'products', 'sensors', 'sensor_readings']
  loop
    execute format('alter view api.%I owner to api_reader', v);
    execute format('revoke all on api.%I from public, anon, authenticated, service_role', v);
    execute format('grant select on api.%I to authenticated', v);
  end loop;
end $$;

comment on view api.horses is 'Horses the caller can read (direct membership or inherited via stable). my_roles = effective roles.';
comment on view api.sensor_readings is 'Time series. Always filter by sensor_id and a recorded_at range.';
