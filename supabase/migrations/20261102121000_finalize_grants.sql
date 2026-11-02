-- =============================================================================
-- 0011 · Finalize least-privilege posture
--
-- Ownership is assigned, so the owner roles no longer need CREATE on api.
-- Re-assert that client roles have nothing in private/app. pgTAP
-- (supabase/tests/database/01_privileges.test.sql) asserts this stays true.
-- =============================================================================

revoke create on schema api from api_reader, api_writer;
revoke create on schema private, app from public, anon, authenticated, service_role, api_reader, api_writer;

revoke all on all tables    in schema private from anon, authenticated, service_role;
revoke all on all sequences in schema private from anon, authenticated, service_role;
revoke all on all functions in schema app     from public, anon, authenticated, service_role;
revoke usage on schema private from anon, authenticated, service_role;
revoke usage on schema app from anon, service_role;
-- authenticated keeps exactly the guarded functions that views/policies call
-- implicitly (see app.is_untrusted_probe in 0004).
grant execute on function app.uid(), app.is_untrusted_probe(uuid), app.horse_roles(uuid, uuid),
  app.has_permission(uuid, text, uuid, text) to authenticated;

-- New objects created later by the migration role start with zero client grants.
alter default privileges for role postgres in schema api revoke execute on functions from public;
alter default privileges for role postgres in schema api revoke all on tables from public, anon, authenticated, service_role;
