-- =============================================================================
-- 0006 · Idempotency + outbox helpers (used inside api write functions)
-- =============================================================================

-- Claim an idempotency key for the current user.
--   * new key            -> returns NULL, caller does the work then calls _finish
--   * replay (same req)  -> returns the stored response, caller returns it as-is
--   * same key, new req  -> 409 idempotency_key_reused
-- Concurrent retries serialize on the primary key: the second insert waits for
-- the first transaction and then sees the committed row.
create or replace function app.idempotency_begin(p_key uuid, p_operation text, p_request jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_user  uuid := app.require_user();
  v_hash  text := encode(sha256(convert_to(p_operation || ':' || coalesce(p_request::text, ''), 'UTF8')), 'hex');
  v_row   private.idempotency_keys;
begin
  if p_key is null then
    perform app.raise_error('22023', 'idempotency_key_required', 'p_idempotency_key must be a client-generated UUID');
  end if;

  insert into private.idempotency_keys (user_id, key, operation, request_hash)
  values (v_user, p_key, p_operation, v_hash)
  on conflict (user_id, key) do nothing;

  if found then
    return null;
  end if;

  select * into v_row from private.idempotency_keys where user_id = v_user and key = p_key;
  if v_row.operation <> p_operation or v_row.request_hash <> v_hash then
    perform app.raise_error('PT409', 'idempotency_key_reused',
      'This idempotency key was already used for a different request');
  end if;
  return v_row.response;
end;
$$;

create or replace function app.idempotency_finish(p_key uuid, p_response jsonb)
returns jsonb
language sql
set search_path = ''
as $$
  update private.idempotency_keys
     set response = p_response
   where user_id = app.uid() and key = p_key;
  select p_response;
$$;

create or replace function app.enqueue_outbox(p_topic text, p_aggregate_type text, p_aggregate_id uuid, p_payload jsonb)
returns void
language sql
set search_path = ''
as $$
  insert into private.outbox (topic, aggregate_type, aggregate_id, payload)
  values (p_topic, p_aggregate_type, p_aggregate_id,
          p_payload || jsonb_build_object('occurred_at', clock_timestamp(), 'actor_id', app.uid()));
$$;

-- Housekeeping, intended for pg_cron in production.
create or replace function app.purge_idempotency_keys(p_older_than interval default interval '7 days')
returns int
language sql
security definer
set search_path = ''
as $$
  with d as (delete from private.idempotency_keys where created_at < now() - p_older_than returning 1)
  select count(*)::int from d;
$$;

revoke all on function app.idempotency_begin(uuid, text, jsonb), app.idempotency_finish(uuid, jsonb),
  app.enqueue_outbox(text, text, uuid, jsonb), app.purge_idempotency_keys(interval)
from public, anon, authenticated, service_role;
grant execute on function app.idempotency_begin(uuid, text, jsonb), app.idempotency_finish(uuid, jsonb),
  app.enqueue_outbox(text, text, uuid, jsonb)
to api_writer;
