-- =============================================================================
-- 0001 · Schemas and least-privilege roles
--
--   private  base tables. No grants to anon / authenticated / service_role.
--   app      internal helpers (permission engine, idempotency, outbox enqueue).
--            Not exposed via the Data API, no grants to client roles.
--   api      the ONLY schema exposed through the Data API (PostgREST).
--            Contains read-only views and SECURITY DEFINER functions.
--
-- Two NOLOGIN roles own the api objects so that nothing runs as a superuser:
--   api_reader  owns every api view and read function. SELECT only, NOBYPASSRLS,
--               so row level security on private tables is enforced for it.
--   api_writer  owns every api write function. SELECT/INSERT/UPDATE on the
--               tables it needs (never DELETE: deletes are soft), NOBYPASSRLS.
-- =============================================================================

create schema if not exists private;
create schema if not exists app;
create schema if not exists api;

-- Nobody gets anything by default in the new schemas.
revoke all on schema private, app, api from public;
alter default privileges in schema private, app, api revoke all on tables from public;
alter default privileges in schema private, app, api revoke all on sequences from public;
alter default privileges in schema private, app, api revoke execute on functions from public;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'api_reader') then
    create role api_reader nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'api_writer') then
    create role api_writer nologin nosuperuser nocreatedb nocreaterole noinherit nobypassrls;
  end if;
end $$;

-- The migration role must be able to hand ownership to these roles.
grant api_reader to postgres;
grant api_writer to postgres;

-- Client-facing roles may only see the api schema.
grant usage on schema api to anon, authenticated, service_role;

-- Owner roles need to resolve objects in the internal schemas.
grant usage on schema private, app to api_reader, api_writer;
grant usage on schema api to api_reader, api_writer;
-- ALTER ... OWNER TO requires CREATE on the target schema. Revoked again in the
-- final migration (20261102121000_finalize_grants.sql) once ownership is set.
grant create on schema api to api_reader, api_writer;

comment on schema private is 'Base tables. Never exposed, never granted to client roles.';
comment on schema app is 'Internal helpers: permission engine, idempotency, outbox. Not exposed.';
comment on schema api is 'Public contract for mobile apps: read-only views + security definer write functions.';
