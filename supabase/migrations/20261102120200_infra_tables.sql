-- =============================================================================
-- 0003 · Infrastructure tables: idempotency keys, transactional outbox,
--        inbound webhook log
-- =============================================================================

-- Client-generated idempotency keys. Unique per (user, key). A retry with the
-- same key and same request returns the stored response; the same key with a
-- different request is rejected (409) so client bugs surface instead of being
-- silently swallowed.
create table private.idempotency_keys (
  user_id       uuid not null references auth.users (id),
  key           uuid not null,
  operation     text not null,
  request_hash  text not null,
  response      jsonb,
  created_at    timestamptz not null default now(),
  constraint idempotency_keys_pk primary key (user_id, key)
);
create index idempotency_keys_created_idx on private.idempotency_keys (created_at);

-- Transactional outbox. Rows are inserted by write functions in the SAME
-- transaction as the business change, then delivered by the outbox-processor
-- edge function (at-least-once, exponential backoff, dead-lettering).
create table private.outbox (
  id              bigint generated always as identity primary key,
  topic           text not null check (topic ~ '^[a-z_]+\.[a-z_]+$'),
  aggregate_type  text not null,
  aggregate_id    uuid not null,
  payload         jsonb not null,
  status          text not null default 'pending' check (status in ('pending', 'processing', 'done', 'dead')),
  attempts        int not null default 0,
  max_attempts    int not null default 6,
  available_at    timestamptz not null default now(),
  locked_at       timestamptz,
  locked_by       text,
  last_error      text,
  created_at      timestamptz not null default now(),
  processed_at    timestamptz
);
create index outbox_pending_idx on private.outbox (available_at, id) where status in ('pending', 'processing');

-- Inbound webhooks, recorded idempotently by (provider, event_id).
create table private.webhook_events (
  id                   bigint generated always as identity primary key,
  provider             text not null check (provider ~ '^[a-z0-9_-]{2,40}$'),
  event_id             text not null check (char_length(event_id) between 1 and 200),
  event_type           text,
  payload              jsonb not null,
  signed_at            timestamptz not null,
  received_at          timestamptz not null default now(),
  constraint webhook_events_provider_event_uq unique (provider, event_id)
);
