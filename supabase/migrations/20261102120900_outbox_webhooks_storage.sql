-- =============================================================================
-- 0010 · Service-role-only operations: outbox processing, inbound webhooks,
--        private storage bucket for horse media
--
-- These functions live in api (the only exposed schema) but EXECUTE is granted
-- to service_role only. Edge functions call them with the service key.
-- =============================================================================

-- Claim up to p_batch pending messages. SKIP LOCKED lets several processor
-- instances run concurrently without double-claiming. Messages stuck in
-- 'processing' longer than p_lock_timeout (crashed worker) are reclaimed.
create or replace function api.outbox_claim(
  p_worker        text,
  p_batch         int      default 20,
  p_lock_timeout  interval default interval '5 minutes'
)
returns table (id bigint, topic text, aggregate_type text, aggregate_id uuid, payload jsonb, attempts int, created_at timestamptz)
language sql
security definer
set search_path = ''
as $$
  with picked as (
    select o.id
    from private.outbox o
    where (o.status = 'pending' and o.available_at <= now())
       or (o.status = 'processing' and o.locked_at < now() - p_lock_timeout)
    order by o.id
    limit least(greatest(p_batch, 1), 100)
    for update skip locked
  )
  update private.outbox o
     set status = 'processing', locked_at = now(), locked_by = p_worker, attempts = o.attempts + 1
    from picked
   where o.id = picked.id
  returning o.id, o.topic, o.aggregate_type, o.aggregate_id, o.payload, o.attempts, o.created_at
$$;

create or replace function api.outbox_complete(p_id bigint, p_worker text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with u as (
    update private.outbox
       set status = 'done', processed_at = now(), locked_at = null, last_error = null
     where id = p_id and status = 'processing' and locked_by = p_worker
    returning 1
  )
  select exists (select 1 from u)
$$;

-- Exponential backoff: 30s, 60s, 120s ... capped at 1h. After max_attempts the
-- message is dead-lettered (status 'dead') for manual inspection.
create or replace function api.outbox_fail(p_id bigint, p_worker text, p_error text)
returns text
language sql
security definer
set search_path = ''
as $$
  update private.outbox
     set status       = case when attempts >= max_attempts then 'dead' else 'pending' end,
         available_at = now() + least(interval '30 seconds' * power(2, greatest(attempts - 1, 0)), interval '1 hour'),
         locked_at    = null,
         last_error   = left(p_error, 2000)
   where id = p_id and status = 'processing' and locked_by = p_worker
  returning status
$$;

-- Record an inbound webhook exactly once. Signature/timestamp checks happen in
-- the webhook-receiver edge function; the unique (provider, event_id)
-- constraint is the replay guard that survives restarts and multiple instances.
create or replace function api.record_webhook_event(
  p_provider   text,
  p_event_id   text,
  p_event_type text,
  p_payload    jsonb,
  p_signed_at  timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  perform app.check_arg(p_provider ~ '^[a-z0-9_-]{2,40}$', 'invalid_provider');
  perform app.check_arg(char_length(p_event_id) between 1 and 200, 'invalid_event_id');
  perform app.check_arg(jsonb_typeof(p_payload) = 'object', 'invalid_payload');

  insert into private.webhook_events (provider, event_id, event_type, payload, signed_at)
  values (p_provider, p_event_id, p_event_type, p_payload, p_signed_at)
  on conflict (provider, event_id) do nothing
  returning id into v_id;

  if v_id is null then
    select w.id into v_id from private.webhook_events w where w.provider = p_provider and w.event_id = p_event_id;
    return jsonb_build_object('status', 'duplicate', 'id', v_id);
  end if;
  return jsonb_build_object('status', 'recorded', 'id', v_id);
end;
$$;

revoke all on function
  api.outbox_claim(text, int, interval),
  api.outbox_complete(bigint, text),
  api.outbox_fail(bigint, text, text),
  api.record_webhook_event(text, text, text, jsonb, timestamptz)
from public, anon, authenticated, service_role;
grant execute on function
  api.outbox_claim(text, int, interval),
  api.outbox_complete(bigint, text),
  api.outbox_fail(bigint, text, text),
  api.record_webhook_event(text, text, text, jsonb, timestamptz)
to service_role;
grant execute on function app.check_arg(boolean, text, text) to postgres;

-- -----------------------------------------------------------------------------
-- Private bucket for horse media. No storage.objects policies for client
-- roles: the only way in is a short-lived signed URL from the horse-media-url
-- edge function, which checks app.has_permission first.
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('horse-media', 'horse-media', false, 20 * 1024 * 1024,
        array['image/jpeg', 'image/png', 'image/heic', 'video/mp4', 'application/pdf'])
on conflict (id) do nothing;
