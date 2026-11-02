# API contract (v1)

This is the contract between the Supabase backend and the iOS/Android apps. Mobile devs can build against it in parallel with backend work. Every item here is covered by a test in `supabase/tests/database/` or `tests/api/`.

- **Base URL:** `https://<project>.supabase.co/rest/v1` (local: `http://127.0.0.1:54321/rest/v1`)
- **Schema:** everything lives in the `api` schema. Send `Accept-Profile: api` on reads and `Content-Profile: api` on RPCs, or set `db: { schema: 'api' }` in supabase-js / supabase-swift / supabase-kt.
- **Auth:** `apikey: <anon key>` plus `Authorization: Bearer <user access token>`. The only call that works without a user token is `product_passport`.
- **Reads:** `GET /<view>` with PostgREST filters, e.g. `GET /horses?select=id,name,my_roles&order=name`.
- **Writes:** only `POST /rpc/<function>` with a JSON body. Argument names are the parameter names shown below, `p_` prefix included. Views reject `POST`/`PATCH`/`DELETE` with 403.

## Conventions

### Idempotency (all writes)

Every write takes `p_idempotency_key`, a **UUID the client generates once per user intent** and stores alongside the pending operation in its offline queue. Re-send the same key on every retry.

| Situation | Result |
|---|---|
| first call | performed, result stored |
| retry with same key + same arguments | **the stored result is returned**, nothing is written again (no duplicate rows, no duplicate side effects) |
| same key + different arguments, or a different function | `409 idempotency_key_reused` (this is a client bug, so it fails loudly) |
| same UUID used by another user | independent (keys are scoped per user) |

If a call fails (4xx/5xx), nothing is stored, so retrying the same key is safe.

### Errors

PostgREST returns `{ "code": "<sqlstate>", "message": "<error_code>", "details": "<human text>", "hint": null }`. **Switch on `message`.** It is a stable machine code, and `details` is for logs.

| HTTP | sqlstate | `message` examples | Meaning |
|---|---|---|---|
| 400 | `22023` | `invalid_name`, `invalid_duration`, `invalid_role`, `horse_not_in_stable`, `idempotency_key_required` | validation failed |
| 401 | `42501` (anon) / PGRST301 | n/a | missing or invalid JWT |
| 403 | `42501` | `forbidden` | you can see the resource but lack the permission |
| 404 | `PT404` | `not_found`, `user_not_found`, `product_not_found` | doesn't exist **or you can't see it** (no existence leak) |
| 409 | `PT409` | `idempotency_key_reused`, `last_owner`, `product_already_registered`, `device_already_registered` | conflict |

### Roles and permissions

Roles are held **per resource** (a membership = user × horse, or user × stable). The same user can be `owner` of one horse, `trainer` of another and a stranger to a third.

| Horse action | owner | trainer | rider | stable_manager¹ | viewer |
|---|:-:|:-:|:-:|:-:|:-:|
| read | ✓ | ✓ | ✓ | ✓ | ✓ |
| read_media | ✓ | ✓ | ✓ | ✓ | ✓ |
| read_training | ✓ | ✓ | ✓ | ✓ | |
| log_training | ✓ | ✓ | ✓ | | |
| read_sensor_data / write_sensor_data | ✓ | ✓ | | ✓ | |
| write_media | ✓ | ✓ | | ✓ | |
| manage_sensors | ✓ | | | ✓ | |
| update, delete, manage_members, manage_owners, manage_training | ✓ | | | | |

¹ Not stored on the horse. A user with `owner` or `stable_manager` on a **stable** inherits `stable_manager` on every horse whose `stable_id` is that stable. The inheritance ends when the horse leaves the stable.

| Stable action | owner | stable_manager | trainer | rider | viewer |
|---|:-:|:-:|:-:|:-:|:-:|
| read | ✓ | ✓ | ✓ | ✓ | ✓ |
| read_tasks, complete_task, board_horse | ✓ | ✓ | ✓ | ✓ | |
| update, manage_members, manage_tasks | ✓ | ✓ | | | |
| delete, manage_owners | ✓ | | | | |

Use `my_roles` / `my_role` on the views, or `rpc/my_permissions`, to drive UI (hide buttons). The server enforces the rules regardless.

---

## Read-only views

All views apply the permission rules above. Rows you can't read simply don't appear. Soft-deleted rows are hidden here and come through `sync_changes` as tombstones.

| View | Columns | Visible when |
|---|---|---|
| `horses` | `id, name, breed, birth_year, color, stable_id, created_at, updated_at, my_roles text[]` | `read` on the horse |
| `stables` | `id, name, city, country, created_at, updated_at, my_role` | `read` on the stable |
| `memberships` | `id, user_id, resource_type ('horse'\|'stable'), resource_id, role, granted_by, created_at, updated_at` | your own memberships, plus all members of resources you can read |
| `training_logs` | `id, horse_id, author_id, started_at, duration_minutes, discipline, intensity, notes, created_at, updated_at` | `read_training` on the horse |
| `stable_tasks` | `id, stable_id, horse_id, title, details, due_at, assigned_to, status ('open'\|'done'), completed_by, completed_at, created_by, created_at, updated_at` | `read_tasks` on the stable |
| `products` | `id, qr_code, gtin, name, manufacturer, category, passport jsonb, owner_id, horse_id, registered_at, updated_at` | you own it, or it is linked to a horse you can read |
| `sensors` | `id, horse_id, device_id, label, created_at, updated_at` | `read_sensor_data` or `manage_sensors` on the horse |
| `sensor_readings` | `id, sensor_id, device_id, recorded_at, temperature_c, humidity_pct, received_at` | `read_sensor_data` on the sensor's horse. **Always filter** by `sensor_id` and a `recorded_at` range: `?sensor_id=eq.<id>&recorded_at=gte.<iso>&order=recorded_at.desc&limit=500` |

Max 1000 rows per request (PostgREST `max_rows`). Paginate with `limit`/`offset` or by key ranges.

---

## Write functions (`POST /rpc/<name>`)

All writes return a JSON object. `updated_at` in the response can be stored as the local row version.

### Horses

**`create_horse`** `(p_idempotency_key uuid, p_name text, p_breed text?, p_birth_year int?, p_color text?, p_stable_id uuid?)`
→ `{ id, name, breed, birth_year, color, stable_id, my_roles: ["owner"], updated_at }`
- Caller becomes `owner`. With `p_stable_id`, the caller needs `board_horse` on that stable.
- Errors: `invalid_name` (1–80 chars), `invalid_birth_year` (1980..current year), `not_found` (stable).

**`update_horse`** `(p_idempotency_key, p_horse_id uuid, p_name?, p_breed?, p_birth_year?, p_color?)`: partial update, where `null` means unchanged. Needs `update`.
→ `{ id, name, breed, birth_year, color, stable_id, updated_at }`

**`move_horse`** `(p_idempotency_key, p_horse_id uuid, p_stable_id uuid | null)` boards the horse at a stable, or removes it from one with `null`. Needs `update` on the horse and `board_horse` on the target stable. Stable staff gain or lose inherited access immediately.
→ `{ id, stable_id, updated_at }`

**`delete_horse`** `(p_idempotency_key, p_horse_id uuid)` soft-deletes the horse. Needs `delete`. → `{ id, deleted: true, updated_at }`

### Memberships

**`grant_membership`** `(p_idempotency_key, p_resource_type 'horse'|'stable', p_resource_id uuid, p_user_id uuid, p_role text)`
- Horse roles: `owner, trainer, rider, viewer`. Stable roles: `owner, stable_manager, trainer, rider, viewer`.
- Needs `manage_members`. Granting or replacing an `owner` additionally needs `manage_owners`.
- Calling it on an existing member changes their role. The old membership is revoked, which shows up in their sync.
- Errors: `invalid_role`, `invalid_resource_type`, `user_not_found`, `forbidden`, `last_owner`.
→ `{ id, user_id, resource_type, resource_id, role, updated_at }`

**`revoke_membership`** `(p_idempotency_key, p_membership_id uuid)` removes a member. Users can always revoke their own membership (leave). Revoking someone else needs `manage_members`, plus `manage_owners` if the target is an owner. Fails with `last_owner` if it would leave the resource ownerless.
→ `{ id, revoked: true, updated_at }`

### Stables and tasks

**`create_stable`** `(p_idempotency_key, p_name text, p_city text?, p_country text?)`: `p_country` is ISO 3166-1 alpha-2 (`DE`). The caller becomes `owner`.
→ `{ id, name, city, country, my_role: "owner", updated_at }`

**`create_stable_task`** `(p_idempotency_key, p_stable_id uuid, p_title text, p_details text?, p_due_at timestamptz?, p_horse_id uuid?, p_assigned_to uuid?)`
- Needs `manage_tasks`. `p_horse_id` must be boarded at the stable (`horse_not_in_stable`), and `p_assigned_to` must be a stable member (`assignee_not_member`).
- **Side effect:** if assigned, a `task.assigned` outbox event is enqueued (push notification).
→ the task object (same columns as the `stable_tasks` view)

**`complete_stable_task`** `(p_idempotency_key, p_task_id uuid)` needs `complete_task`. Completing a task that is already done returns it unchanged, so two people tapping "done" while offline converge without an error. **Side effect:** `task.completed`.
→ task object

### Training logs

**`log_training`** `(p_idempotency_key, p_horse_id uuid, p_started_at timestamptz, p_duration_minutes int, p_discipline text, p_intensity text = 'moderate', p_notes text?)`
- Needs `log_training`. `p_discipline` ∈ `dressage, jumping, eventing, endurance, western, groundwork, hacking, lunging, other`; `p_intensity` ∈ `light, moderate, hard`.
- `p_started_at` must be within the last 2 years and not in the future (5 min clock-skew allowance). `p_duration_minutes` must be 1–600.
→ log object

**`delete_training_log`** `(p_idempotency_key, p_log_id uuid)` soft-deletes a log. Allowed for the author (while they can still log training on that horse) or the horse owner. → `{ id, deleted: true, updated_at }`

### Products (QR registration and Digital Product Passport)

**`product_passport`** `(p_qr_code text)` is **public (anon allowed)**. Use it right after scanning, before or without login.
→ `{ qr_code, gtin, name, manufacturer, category, passport: {...}, is_registered }` or `null` if unknown. Never reveals the owner.

**`register_product`** `(p_idempotency_key, p_qr_code text, p_horse_id uuid?)` claims a scanned product for the caller and optionally links it to a horse (needs `update` on that horse). The input is trimmed and upper-cased. Re-registering your own product (for example to change the horse) is allowed.
- Errors: `invalid_qr_code`, `product_not_found`, `product_already_registered` (409).
- **Side effect:** the first registration enqueues `product.registered` (manufacturer warranty / DPP registry).
→ product object

### Sensors

**`register_sensor`** `(p_idempotency_key, p_horse_id uuid, p_device_id text, p_label text?)` needs `manage_sensors`. `device_id` must match `[A-Za-z0-9:_-]{4,64}` and be globally unique (`device_already_registered`, 409).
→ sensor object

**`sync_sensor_readings`** `(p_idempotency_key uuid, p_readings jsonb[])` is the offline batch upload, 1–1000 rows.

```json
{ "p_idempotency_key": "6f1c…", "p_readings": [
  { "device_id": "SC1-00A4-7F21", "recorded_at": "2026-11-02T10:00:00Z", "temperature_c": 18.4, "humidity_pct": 62.0 }
]}
```

→
```json
{ "received": 3, "accepted": 1, "duplicates": 1,
  "rejected": [ { "index": 2, "device_id": "SC1-00A4-7F21", "recorded_at": "2026-11-03T10:00:00Z", "reason": "recorded_at_in_future" } ] }
```

- **Partial acceptance:** valid rows are stored and invalid rows are reported by their array `index`. The request itself only fails (400) when the payload is not an array (`readings_must_be_array`) or has a bad size (`invalid_batch_size`).
- **Idempotent per `(device_id, recorded_at)`:** re-uploading a reading counts it under `duplicates`. The first write wins, and duplicates never overwrite.
- Row `reason` values: `invalid_row`, `invalid_value`, `invalid_device_id`, `missing_recorded_at`, `recorded_at_in_future` (> 5 min ahead), `recorded_at_too_old` (> 90 days), `no_measurement`, `temperature_out_of_range` (−50..80 °C), `humidity_out_of_range` (0..100 %), `unknown_device` (not registered **or not visible to you**), `forbidden`.
- **Client rule:** drop `accepted` and `duplicates` rows from the local queue. For `rejected` rows, drop them too unless the reason is transient for your app (none of the current reasons are).
- **Side effect:** an accepted reading ≥ 32 °C enqueues one `sensor.heat_alert` per sensor per batch.

---

## Offline-first delta sync

**`sync_changes`** `(p_since_ts timestamptz?, p_since_id uuid?, p_limit int = 500)` (max 1000)

→ rows ordered by `(sync_ts, id)`:
```json
[ { "entity": "horse", "id": "…", "sync_ts": "2026-11-02T10:15:03.123456+00:00", "deleted": false, "data": { "name": "Nordwind", … } },
  { "entity": "training_log", "id": "…", "sync_ts": "…", "deleted": true, "data": null } ]
```

- `entity` ∈ `membership, stable, horse, training_log, stable_task, sensor, product`.
- **Algorithm:** start with `null, null`. Upsert every row with `deleted: false` into the local DB by `(entity, id)`. Delete every row with `deleted: true`. Save the **last** row's `(sync_ts, id)` as the cursor. Repeat until a page comes back empty.
- **Tombstones:** soft-deleted rows come through with `deleted: true` and `data: null`.
- **Access gained:** when you're invited to a horse (or your stable takes in a horse), that horse and all of its children come through on your next sync, **even rows last edited before your cursor**.
- **Access lost:** you receive your own `membership` row with `deleted: true`. Purge that resource and everything under it locally. (Horses inherited through a stable: when a horse leaves your stable, the next full sync no longer includes it. Run a full re-sync (`null` cursor) daily, or when the app resumes after more than 7 days, to reconcile.)
- **Sensor readings are not part of delta sync** because the volume is too large. Query the `sensor_readings` view by time window.
- Writes made offline go through the write functions (with their idempotency keys) when back online. Then pull `sync_changes` to get the authoritative state.

---

## Permissions introspection

**`my_permissions`** `(p_resource_type 'horse'|'stable', p_resource_id uuid)` → `text[]`, e.g. `["read","read_media"]`. Returns `[]` for resources you can't access.

---

## Edge functions (`https://<project>.supabase.co/functions/v1/<name>`)

### `horse-media-url` (user JWT required)
`POST { "horse_id": uuid, "path": "photos/2026/front.jpg", "mode": "download" | "upload" }`

| Status | Body |
|---|---|
| 200 | `{ signed_url, path: "<horse_id>/<path>", bucket: "horse-media", expires_in: 300 }` (download) or `{ signed_url, token, path, bucket }` (upload, use with `uploadToSignedUrl`) |
| 400 | `invalid_horse_id`, `invalid_path` (segments `[A-Za-z0-9._-]`, max 5 levels, no `..`), `invalid_mode` |
| 401 | missing or invalid JWT |
| 403 | can see the horse but lacks `read_media` (download) or `write_media` (upload) |
| 404 | horse not visible to you |

Objects are always stored under `<horse_id>/…`. The bucket is private and has no client storage policies, so a signed URL from this function is the only way in.

### `webhook-receiver` (for external systems, signed with HMAC; not for the apps)
Headers: `x-webhook-id`, `x-webhook-timestamp` (unix seconds), `x-webhook-signature: v1=<hex hmac_sha256(secret, id + "." + timestamp + "." + raw_body)>`.
200 `{status: "recorded"|"duplicate"}` · 400 missing headers / timestamp outside ±300 s / invalid JSON · 401 bad signature · 413 > 256 KB.

### `outbox-processor` (internal)
Triggered by a scheduler with the `x-cron-secret` header. It delivers outbox events as signed webhooks using the same signature scheme. Delivery is **at least once**: consumers must dedupe on `x-webhook-id` (`outbox-<id>`).

### Outbox event topics

| Topic | Payload (`data`) | Emitted by |
|---|---|---|
| `task.assigned` | `task_id, stable_id, assigned_to, title, due_at` | `create_stable_task` with assignee |
| `task.completed` | `task_id, stable_id, completed_by, title` | `complete_stable_task` |
| `product.registered` | `product_id, qr_code, gtin, manufacturer, registered_at` | first `register_product` |
| `sensor.heat_alert` | `sensor_id, max_temperature_c, threshold_c` | `sync_sensor_readings` |

Every payload also carries `occurred_at` and `actor_id`.
