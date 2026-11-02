# stable-backend-demo

A backend-only reference implementation on **Supabase** for a mobile platform for horse owners, riders and stables. Native iOS and Android apps talk directly to the Supabase Data API (PostgREST). There is no UI in this repo. **All data is fictional.**

What it demonstrates:

- **RLS on every table** and **least-privilege roles and grants**. Client roles have zero privileges on base tables.
- **Versioned migrations** that are applied from scratch on every CI run.
- An **`api` schema** with only read-only views and `SECURITY DEFINER` functions for every write.
- **Context-based permissions** with **one central check**, `app.has_permission(user, resource_type, resource_id, action)`.
- **Idempotent writes** (client-generated keys), a **transactional outbox**, **offline-first delta sync**, and **sensor time-series** batch upload with partial accept.
- **Edge functions** (Deno/TypeScript): outbox processor with retries, signed-webhook receiver (HMAC, timestamp tolerance, replay protection), and a signed storage URL issuer.
- **Tests in CI:** pgTAP permission tests, Deno unit tests, and HTTP end-to-end tests against PostgREST/GoTrue. CI also runs a full-history secret scan.

`API.md` is the contract for mobile developers.

---

## Architecture

```
 iOS / Android app
   │  supabase-swift / supabase-kt   (apikey + user JWT, schema "api")
   ▼
 ┌────────────────────────── Supabase (EU region) ───────────────────────────┐
 │  PostgREST (Data API) ── exposes ONLY schema `api`                         │
 │     │                                                                      │
 │     ├─ GET  /horses, /training_logs, … ─▶ api.* VIEWS  (owner: api_reader) │
 │     └─ POST /rpc/<fn>                 ─▶ api.* FUNCTIONS (owner: api_writer)│
 │                                            │ validate · idempotency ·      │
 │                                            │ has_permission · outbox       │
 │                                            ▼                               │
 │  schema `app`      app.has_permission() ◀── every RLS policy + every write │
 │  schema `private`  base tables, RLS ON, no grants to anon/authenticated    │
 │                    outbox · idempotency_keys · webhook_events              │
 │                                                                            │
 │  Edge functions (Deno)                                                     │
 │    outbox-processor   claim (SKIP LOCKED) → signed webhook → complete/fail │
 │    webhook-receiver   HMAC + ±300s + unique(provider,event_id)             │
 │    horse-media-url    my_permissions (as caller) → signed URL (service)    │
 │  Storage: private bucket `horse-media`, objects under <horse_id>/…         │
 └────────────────────────────────────────────────────────────────────────────┘
```

### Schemas and roles

| Schema | Contents | Who can use it |
|---|---|---|
| `private` | base tables (horses, stables, memberships, stable_tasks, training_logs, products, sensors, sensor_readings, role_permissions, idempotency_keys, outbox, webhook_events) | only the owner roles below; **no grants to anon / authenticated / service_role** |
| `app` | permission engine, idempotency/outbox helpers | the owner roles. `authenticated` may execute only the 4 guarded functions that views/policies call implicitly (`uid`, `has_permission`, `horse_roles`, `is_untrusted_probe`) |
| `api` | read-only views + SECURITY DEFINER functions | `authenticated` (views + user functions), `anon` (only `product_passport`), `service_role` (only outbox/webhook ops) |

Two `NOLOGIN NOBYPASSRLS` roles own the `api` objects, so nothing in the request path runs as a superuser:

- **`api_reader`** owns every view and read function. It has `SELECT` on `private` and nothing else.
- **`api_writer`** owns every write function. It has `SELECT/INSERT/UPDATE` on the tables it needs. It **never** has `DELETE`, because deletes are soft deletes (`deleted_at`, `revoked_at`) so offline clients receive tombstones.

Neither role owns the tables and neither bypasses RLS. Policies are therefore evaluated **for every view read and every write**, using the caller's JWT (`app.uid()` reads `request.jwt.claims`). That is defense in depth: if a write function forgot a check, RLS would still stop it, and one pgTAP test proves exactly that.

### Migrations

`supabase/migrations/` (timestamped and applied in order):

| # | File | What |
|---|---|---|
| 1 | `…120000_schemas_and_roles` | schemas, owner roles, default-privilege lockdown |
| 2 | `…120100_core_tables` | domain tables, soft-delete columns, sync indexes, `updated_at` triggers (`clock_timestamp()`) |
| 3 | `…120200_infra_tables` | idempotency keys, outbox, webhook events |
| 4 | `…120300_permissions` | `role_permissions` matrix, `app.has_permission`, error helpers |
| 5 | `…120400_rls_and_grants` | RLS on every table, policies, table grants |
| 6 | `…120500_idempotency_outbox_helpers` | `idempotency_begin/finish`, `enqueue_outbox` |
| 7 | `…120600_api_views` | read-only views |
| 8 | `…120700_api_write_functions` | all write RPCs |
| 9 | `…120800_offline_sync` | `sync_sensor_readings`, `sync_changes` |
| 10 | `…120900_outbox_webhooks_storage` | service-role ops functions, private bucket |
| 11 | `…121000_finalize_grants` | revoke temporary CREATE, re-assert the lockdown |

---

## How permissions work

**Memberships** connect a user to a resource with a role: `user × horse` or `user × stable`, with role `owner | trainer | rider | stable_manager | viewer`. Permissions depend on **context**. Bob can be the trainer of Thunder and the owner of Pepper, and those two rights never mix.

**`private.role_permissions`** is the matrix (role → allowed actions per resource type) and lives as data, so changing what a trainer may do is a one-row migration. See the tables in `API.md`.

**Inheritance:** an `owner` or `stable_manager` of a **stable** acts as `stable_manager` on every horse whose `stable_id` is that stable. This is computed at check time, not copied into memberships, so access appears and disappears as horses move.

**One central check:**

```sql
app.has_permission(p_user uuid, p_resource_type text, p_resource_id uuid, p_action text) returns boolean
```

- `horse`, `stable`: effective roles (direct + inherited) joined to `role_permissions`.
- Child resources resolve to their parent: `training_log` → horse (`read` = `read_training`, `delete` = author or `manage_training`), `stable_task` → stable, `sensor` → horse, `product` → owner, or a reader of the linked horse.
- It is `SECURITY DEFINER` and `STABLE`, with `search_path = ''`. `authenticated` can execute it, because Postgres evaluates functions in view bodies and RLS policies as the calling role. A guard (`app.is_untrusted_probe`) makes it return `false` whenever a client role asks about **any user other than itself**, so nobody can probe another user's rights. The apps use `api.my_permissions()` to drive their UI.

Every RLS policy calls it (with `(select app.uid())` so the uid is computed once per statement), and every write function calls it through `app.require_permission()`. That returns **404 `not_found`** if you can't even read the resource, so existence is never leaked, and **403 `forbidden`** if you can read it but lack the action.

---

## Write path: validation, idempotency, outbox

Each `api.*` write function follows the same skeleton:

1. `app.require_user()`: 401 without a JWT.
2. `app.idempotency_begin(key, operation, request)`: inserts `(user_id, key)` into `private.idempotency_keys` (primary key = the unique constraint). A replay returns the stored response, the same key with different arguments raises 409, and concurrent duplicates serialize on the key.
3. Input validation, with stable error codes (`invalid_name`, `invalid_duration`, …).
4. `app.require_permission(...)` → `app.has_permission`.
5. Mutate `private.*`, where RLS re-checks as `api_writer`.
6. `app.enqueue_outbox(topic, …)` **in the same transaction** for anything with an external side effect (push notification, manufacturer registration, heat alert).
7. `app.idempotency_finish(key, response)`.

If anything fails, the whole transaction including the key rolls back, so a retry is safe.

**Outbox delivery** (`outbox-processor`): `api.outbox_claim` uses `FOR UPDATE SKIP LOCKED` so several workers can run concurrently. Delivery is a signed webhook. `outbox_fail` schedules an exponential backoff (30 s · 2ⁿ, capped at 1 h) and dead-letters after `max_attempts`. Locks from crashed workers are reclaimed after 5 minutes. Delivery is at least once, and `x-webhook-id = outbox-<id>` lets consumers dedupe.

**Inbound webhooks** (`webhook-receiver`): HMAC-SHA256 over `id.timestamp.body`, constant-time comparison, multiple secrets for rotation, and a ±300 s timestamp tolerance (rejects replays of old captures). `unique(provider, event_id)` in the database is the replay guard: it survives restarts and multiple instances, and a replay returns `200 duplicate`.

**Signed media URLs** (`horse-media-url`): the function first calls `api.my_permissions` **with the caller's own JWT**, which is the same `has_permission` that RLS uses. Only then does it use the service key to sign a 5-minute URL. Object paths are always `<horse_id>/<validated path>`, so traversal is impossible. The bucket has no client policies.

## Offline-first sync

- **Upload:** `api.sync_sensor_readings(key, readings[])` takes up to 1000 rows. Valid rows are inserted with `ON CONFLICT (device_id, recorded_at) DO NOTHING`, and invalid rows are returned as `{index, reason}`. Re-sending is always safe.
- **Download:** `api.sync_changes(since_ts, since_id, limit)` returns `(entity, id, sync_ts, deleted, data)` ordered by `(sync_ts, id)`, so the cursor is a strict tuple comparison. Soft deletes come through as tombstones. When a user **gains** access (an invite, or a horse boarded at their stable), `sync_ts` is lifted to the grant time, so older rows are still delivered. When access is **lost**, the client receives its own membership as a tombstone.
- Sensor readings are append-only time series: `unique(device_id, recorded_at)` doubles as the idempotency key, a btree index on `(sensor_id, recorded_at desc)` serves range queries, and a BRIN index on `recorded_at` serves time-window scans. For production volumes, the next step is monthly partitioning on `recorded_at`; the unique key already includes the partition column.

Known limitations (documented in `API.md`): a horse leaving a stable doesn't emit a tombstone to the stable's staff, so clients run a periodic full re-sync. And `updated_at` cursors can in theory miss a row from a transaction that commits later with an earlier timestamp; the periodic full sync covers that too. A production follow-up would be a per-row sequence (`txid`/LSN-based) cursor.

---

## Running it

Requirements: Docker, [Supabase CLI](https://supabase.com/docs/guides/cli) ≥ 2.122, [Deno](https://deno.com) 2.x.

```bash
supabase start -x studio,imgproxy,mailpit,logflare,vector,realtime,supavisor,postgres-meta
supabase db reset                      # all migrations from scratch + seed.sql (fictional data)

supabase test db                       # pgTAP
deno task test:functions               # edge function unit tests
set -a; eval "$(supabase status -o env)"; set +a
deno task test:api                     # HTTP end-to-end against PostgREST + GoTrue
```

Local demo logins from `seed.sql`: `owner@example.test`, `trainer@example.test`, `manager@example.test` and `viewer@example.test`, password `local-demo-only`. These exist on the local stack only.

Serving the edge functions locally needs these function env vars (in `supabase/functions/.env`, which is gitignored): `WEBHOOK_PROVIDER`, `WEBHOOK_SECRETS` (comma-separated, for rotation), `OUTBOX_CRON_SECRET`, `OUTBOX_SIGNING_SECRET`, and `OUTBOX_TARGET_URL` (leave empty to log instead of deliver). Then:

```bash
supabase functions serve --env-file supabase/functions/.env
```

### Tests

| Suite | Where | What |
|---|---|---|
| pgTAP | `supabase/tests/database/` | `01_privileges`: RLS everywhere, no base-table grants, exact EXECUTE allow-lists per role, view ownership, definer + search_path. `02_permission_matrix`: owner/trainer/rider/viewer/stranger/stable manager/stable owner × actions, cross-horse denial, inheritance, revocation, horse moving stables. `03_rls_reads`: what each persona sees in every view. `04_writes`: rejected without permission (404 vs 403), validation, outbox in the same transaction, RLS defense in depth. `05_idempotency`: retries, key reuse, per-user scope, single side effect. `06_sensor_batch_sync`: partial rejects with reasons, duplicates, resend, heat alert. `07_delta_sync`: pagination = full set, updates, tombstones, access gained/lost, inheritance. `08_outbox_webhooks`: SKIP LOCKED claim, backoff, dead letter, stale lock reclaim, idempotent webhook record |
| Deno unit | `supabase/functions/**/**_test.ts` | HMAC (RFC 4231 vector), tolerance edges, tampering, rotation; webhook handler status codes and replay; outbox drain, retry, dead letter, batch isolation, time budget, signed delivery verifiable by the receiver; media URL permission gating, path traversal, cross-horse denial |
| Deno e2e | `tests/api/` | real HTTP: anon 401, private schema not exposed (PGRST106), RPC create + idempotent retry + 409 reuse, stranger 404, viewer 403, validation 400, views reject POST, sensor batch, delta sync, passport as anon, ops functions denied |

### CI / CD

`.github/workflows/ci.yml` runs on every pull request and every push to `main`:

1. **Secret scan:** gitleaks over the full git history.
2. **Edge functions:** `deno fmt --check`, `deno lint`, `deno check`, unit tests.
3. **Database:** `supabase start`, then `supabase db reset` (all migrations from scratch), `supabase db lint`, `supabase test db`, and the HTTP e2e suite.

`.github/workflows/deploy.yml` is a **placeholder** deploy. It deploys to staging after a green CI run on `main`, and to production on manual dispatch. Secrets come only from the GitHub **environments** `staging` and `production` (production should have required reviewers). Nothing deploys until the repository variable `DEPLOY_ENABLED=true` is set. No secrets are committed.

EU data residency: create the hosted projects in an EU region (e.g. `eu-central-1` Frankfurt). Nothing in this repo is region-specific.

---

## How this was built

Built with **Claude Code** (AI pair-programming in the terminal) from a single written brief, on a local Supabase stack (CLI 2.122, Postgres 17, Docker via Colima). The full timestamped log is in [`BUILD_LOG.md`](BUILD_LOG.md).

| Phase | Time |
|---|---|
| Toolchain setup (Homebrew API unreachable, so binaries were installed manually; slow VM image download) | 40 min, overlapping the phases below |
| Schema, `api` schema, permissions + RLS, write functions, idempotency, offline sync (11 migrations) | 16 min |
| Outbox + 3 edge functions + 38 Deno unit tests | ~4 min |
| pgTAP suites + HTTP e2e tests | ~8 min |
| CI + deploy workflows | ~2 min |
| API.md + README | ~6 min |
| Waiting for the Postgres image (~0.5 MB/s) | 26 min idle |
| First real run, 3 fixes, all suites green | ~3 min |

**Test summary:** 251 pgTAP + 38 Deno unit + 14 HTTP end-to-end = **303 tests, all passing**, plus a clean `supabase db lint`.

What the first run caught, and how it was fixed, is worth knowing if you build something similar. Postgres checks EXECUTE on functions that appear in **view bodies and RLS policy expressions as the calling role**, not the view owner. So `authenticated` needs EXECUTE on `app.uid`, `app.has_permission` and `app.horse_roles`. To keep anyone from probing other users' rights, `app.is_untrusted_probe()` makes both `has_permission` and `horse_roles` return nothing to anon/authenticated for any user other than the caller's own JWT subject. A pgTAP test proves it.
