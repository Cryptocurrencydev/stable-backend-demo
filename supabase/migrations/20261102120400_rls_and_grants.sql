-- =============================================================================
-- 0005 · Row level security on EVERY table + least-privilege table grants
--
-- Client roles (anon, authenticated) get NO table privileges in private.
-- Only the two owner roles get grants, and RLS applies to both of them
-- (they are NOBYPASSRLS and do not own the tables), so a bug in a view or a
-- write function still cannot reach rows the caller lacks permission for.
--
-- Policies always wrap app.uid() in a scalar subquery so Postgres evaluates it
-- once per statement (initplan) rather than once per row.
-- =============================================================================

do $$
declare t record;
begin
  for t in select tablename from pg_tables where schemaname = 'private'
  loop
    execute format('alter table private.%I enable row level security', t.tablename);
    execute format('revoke all on private.%I from public, anon, authenticated, service_role', t.tablename);
  end loop;
end $$;

revoke all on all sequences in schema private from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------- grants
grant select on all tables in schema private to api_reader;

grant select on private.role_permissions to api_writer;
grant select, insert, update on
  private.stables, private.horses, private.memberships, private.stable_tasks,
  private.training_logs, private.products, private.sensors, private.idempotency_keys
to api_writer;
grant select, insert on private.sensor_readings to api_writer;
grant insert on private.outbox to api_writer;
grant usage on all sequences in schema private to api_writer;
-- products: only the registration columns may change through the api
revoke update on private.products from api_writer;
grant update (owner_id, horse_id, registered_at) on private.products to api_writer;

-- ---------------------------------------------------------------- role_permissions
create policy role_permissions_read on private.role_permissions
  for select to api_reader, api_writer using (true);

-- ---------------------------------------------------------------- stables
create policy stables_select on private.stables for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'stable', id, 'read')
         or created_by = (select app.uid()));
create policy stables_insert on private.stables for insert to api_writer
  with check (created_by = (select app.uid()));
create policy stables_update on private.stables for update to api_writer
  using (app.has_permission((select app.uid()), 'stable', id, 'update')
         or app.has_permission((select app.uid()), 'stable', id, 'delete'));

-- ---------------------------------------------------------------- horses
create policy horses_select on private.horses for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'horse', id, 'read')
         or created_by = (select app.uid()));
create policy horses_insert on private.horses for insert to api_writer
  with check (created_by = (select app.uid()));
create policy horses_update on private.horses for update to api_writer
  using (app.has_permission((select app.uid()), 'horse', id, 'update')
         or app.has_permission((select app.uid()), 'horse', id, 'delete'));

-- ---------------------------------------------------------------- memberships
-- You see your own memberships, plus all memberships of resources you manage
-- or can read (so a horse's members list is visible to its members).
create policy memberships_select on private.memberships for select to api_reader, api_writer
  using (
    user_id = (select app.uid())
    or (horse_id  is not null and app.has_permission((select app.uid()), 'horse',  horse_id,  'read'))
    or (stable_id is not null and app.has_permission((select app.uid()), 'stable', stable_id, 'read'))
  );
create policy memberships_insert on private.memberships for insert to api_writer
  with check (
    granted_by = (select app.uid())
    and app.can_grant_membership((select app.uid()),
          case when horse_id is not null then 'horse' else 'stable' end,
          coalesce(horse_id, stable_id), user_id, role)
  );
create policy memberships_update on private.memberships for update to api_writer
  using (
    (horse_id  is not null and app.has_permission((select app.uid()), 'horse',  horse_id,  'manage_members'))
    or (stable_id is not null and app.has_permission((select app.uid()), 'stable', stable_id, 'manage_members'))
    or user_id = (select app.uid())  -- leaving a resource yourself
  );

-- ---------------------------------------------------------------- stable tasks
create policy stable_tasks_select on private.stable_tasks for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'stable', stable_id, 'read_tasks'));
create policy stable_tasks_insert on private.stable_tasks for insert to api_writer
  with check (created_by = (select app.uid())
              and app.has_permission((select app.uid()), 'stable', stable_id, 'manage_tasks'));
create policy stable_tasks_update on private.stable_tasks for update to api_writer
  using (app.has_permission((select app.uid()), 'stable', stable_id, 'complete_task')
         or app.has_permission((select app.uid()), 'stable', stable_id, 'manage_tasks'));

-- ---------------------------------------------------------------- training logs
create policy training_logs_select on private.training_logs for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'horse', horse_id, 'read_training'));
create policy training_logs_insert on private.training_logs for insert to api_writer
  with check (author_id = (select app.uid())
              and app.has_permission((select app.uid()), 'horse', horse_id, 'log_training'));
create policy training_logs_update on private.training_logs for update to api_writer
  using (app.has_permission((select app.uid()), 'training_log', id, 'delete'));

-- ---------------------------------------------------------------- products
create policy products_select on private.products for select to api_reader
  using (owner_id = (select app.uid())
         or app.has_permission((select app.uid()), 'product', id, 'read'));
-- the writer may also see unregistered products, to register them by QR code
create policy products_select_writer on private.products for select to api_writer
  using (owner_id is null or owner_id = (select app.uid())
         or app.has_permission((select app.uid()), 'product', id, 'read'));
create policy products_update on private.products for update to api_writer
  using (owner_id is null or owner_id = (select app.uid()))
  with check (owner_id = (select app.uid())
              and (horse_id is null or app.has_permission((select app.uid()), 'horse', horse_id, 'update')));

-- ---------------------------------------------------------------- sensors
create policy sensors_select on private.sensors for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'horse', horse_id, 'read_sensor_data')
         or app.has_permission((select app.uid()), 'horse', horse_id, 'manage_sensors'));
create policy sensors_insert on private.sensors for insert to api_writer
  with check (created_by = (select app.uid())
              and app.has_permission((select app.uid()), 'horse', horse_id, 'manage_sensors'));
create policy sensors_update on private.sensors for update to api_writer
  using (app.has_permission((select app.uid()), 'horse', horse_id, 'manage_sensors'));

-- ---------------------------------------------------------------- sensor readings
create policy sensor_readings_select on private.sensor_readings for select to api_reader, api_writer
  using (app.has_permission((select app.uid()), 'sensor', sensor_id, 'read')
         or app.has_permission((select app.uid()), 'sensor', sensor_id, 'write_data'));
create policy sensor_readings_insert on private.sensor_readings for insert to api_writer
  with check (app.has_permission((select app.uid()), 'sensor', sensor_id, 'write_data'));

-- ---------------------------------------------------------------- idempotency keys
create policy idempotency_keys_own on private.idempotency_keys for all to api_writer
  using (user_id = (select app.uid()))
  with check (user_id = (select app.uid()));

-- ---------------------------------------------------------------- outbox
-- api_writer may enqueue only; it can never read or modify queued messages.
create policy outbox_enqueue on private.outbox for insert to api_writer
  with check (status = 'pending' and attempts = 0);

-- ---------------------------------------------------------------- webhook_events
-- RLS enabled, no policies: only the table owner (used by the service-role-only
-- api.record_webhook_event function) can touch it.
