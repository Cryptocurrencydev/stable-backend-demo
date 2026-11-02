// End-to-end tests against the running local stack (PostgREST + GoTrue), i.e.
// exactly what the iOS / Android apps will call. Run after `supabase start`:
//
//   eval "$(supabase status -o env)" && deno task test:api
//
import { assert, assertEquals } from "@std/assert";

const URL_ = Deno.env.get("API_URL") ?? Deno.env.get("SUPABASE_URL") ?? "http://127.0.0.1:54321";
const ANON = Deno.env.get("ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE = Deno.env.get("SERVICE_ROLE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

if (!ANON || !SERVICE) throw new Error('ANON_KEY and SERVICE_ROLE_KEY must be set (eval "$(supabase status -o env)")');

const run = crypto.randomUUID().slice(0, 8);

async function createUser(name: string): Promise<string> {
  const email = `${name}-${run}@example.test`;
  const password = `pw-${crypto.randomUUID()}`;
  const created = await fetch(`${URL_}/auth/v1/admin/users`, {
    method: "POST",
    headers: { apikey: SERVICE, authorization: `Bearer ${SERVICE}`, "content-type": "application/json" },
    body: JSON.stringify({ email, password, email_confirm: true }),
  });
  assertEquals(created.status, 200, await created.clone().text());
  await created.body?.cancel();
  const token = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
    method: "POST",
    headers: { apikey: ANON, "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  const json = await token.json();
  assert(json.access_token, JSON.stringify(json));
  return json.access_token;
}

function rest(jwt: string | null, path: string, init: RequestInit & { profile?: string } = {}) {
  const headers: Record<string, string> = {
    apikey: ANON,
    "content-type": "application/json",
    "accept-profile": init.profile ?? "api",
    "content-profile": init.profile ?? "api",
  };
  if (jwt) headers.authorization = `Bearer ${jwt}`;
  return fetch(`${URL_}/rest/v1/${path}`, { ...init, headers: { ...headers, ...(init.headers ?? {}) } });
}

async function rpc(jwt: string | null, fn: string, args: Record<string, unknown>) {
  const res = await rest(jwt, `rpc/${fn}`, { method: "POST", body: JSON.stringify(args) });
  return { status: res.status, body: await res.json() };
}

const owner = await createUser("owner");
const other = await createUser("other");
const otherId = JSON.parse(atob(other.split(".")[1])).sub as string;

let horseId = "";
const createKey = crypto.randomUUID();

Deno.test("anon cannot read horses through the Data API", async () => {
  const res = await rest(null, "horses");
  await res.body?.cancel();
  assertEquals(res.status, 401);
});

Deno.test("private schema is not exposed by PostgREST", async () => {
  const res = await rest(owner, "horses", { profile: "private" });
  const body = await res.json();
  assertEquals(res.status, 406);
  assertEquals(body.code, "PGRST106");
});

Deno.test("create_horse via RPC, then visible in api.horses with my_roles", async () => {
  const r = await rpc(owner, "create_horse", {
    p_idempotency_key: createKey,
    p_name: `E2E ${run}`,
    p_birth_year: 2016,
  });
  assertEquals(r.status, 200, JSON.stringify(r.body));
  horseId = r.body.id;
  const res = await rest(owner, `horses?id=eq.${horseId}&select=name,my_roles`);
  assertEquals(await res.json(), [{ name: `E2E ${run}`, my_roles: ["owner"] }]);
});

Deno.test("retrying create_horse with the same key returns the same horse", async () => {
  const r = await rpc(owner, "create_horse", {
    p_idempotency_key: createKey,
    p_name: `E2E ${run}`,
    p_birth_year: 2016,
  });
  assertEquals(r.status, 200);
  assertEquals(r.body.id, horseId);
  const res = await rest(owner, `horses?name=eq.E2E%20${run}&select=id`);
  assertEquals((await res.json()).length, 1);
});

Deno.test("idempotency key reused for a different request -> 409", async () => {
  const r = await rpc(owner, "create_horse", { p_idempotency_key: createKey, p_name: "Something else" });
  assertEquals(r.status, 409);
  assertEquals(r.body.message, "idempotency_key_reused");
});

Deno.test("stranger: horse invisible, write -> 404 not_found", async () => {
  const res = await rest(other, `horses?id=eq.${horseId}`);
  assertEquals(await res.json(), []);
  const r = await rpc(other, "log_training", {
    p_idempotency_key: crypto.randomUUID(),
    p_horse_id: horseId,
    p_started_at: new Date().toISOString(),
    p_duration_minutes: 30,
    p_discipline: "dressage",
  });
  assertEquals(r.status, 404);
  assertEquals(r.body.message, "not_found");
});

Deno.test("viewer: can read, write -> 403 forbidden", async () => {
  const g = await rpc(owner, "grant_membership", {
    p_idempotency_key: crypto.randomUUID(),
    p_resource_type: "horse",
    p_resource_id: horseId,
    p_user_id: otherId,
    p_role: "viewer",
  });
  assertEquals(g.status, 200, JSON.stringify(g.body));
  const res = await rest(other, `horses?id=eq.${horseId}&select=my_roles`);
  assertEquals(await res.json(), [{ my_roles: ["viewer"] }]);
  const r = await rpc(other, "log_training", {
    p_idempotency_key: crypto.randomUUID(),
    p_horse_id: horseId,
    p_started_at: new Date().toISOString(),
    p_duration_minutes: 30,
    p_discipline: "dressage",
  });
  assertEquals(r.status, 403);
  assertEquals(r.body.message, "forbidden");
});

Deno.test("validation error -> 400 with machine-readable code", async () => {
  const r = await rpc(owner, "log_training", {
    p_idempotency_key: crypto.randomUUID(),
    p_horse_id: horseId,
    p_started_at: new Date().toISOString(),
    p_duration_minutes: 9999,
    p_discipline: "dressage",
  });
  assertEquals(r.status, 400);
  assertEquals(r.body.message, "invalid_duration");
});

Deno.test("views are read-only: POST to a view is rejected", async () => {
  const res = await rest(owner, "horses", { method: "POST", body: JSON.stringify({ name: "Direct insert" }) });
  await res.body?.cancel();
  assertEquals(res.status, 403);
});

Deno.test("offline sensor batch: partial accept over HTTP", async () => {
  const device = `E2E-${run}`;
  const s = await rpc(owner, "register_sensor", {
    p_idempotency_key: crypto.randomUUID(),
    p_horse_id: horseId,
    p_device_id: device,
  });
  assertEquals(s.status, 200, JSON.stringify(s.body));
  const now = Date.now();
  const r = await rpc(owner, "sync_sensor_readings", {
    p_idempotency_key: crypto.randomUUID(),
    p_readings: [
      { device_id: device, recorded_at: new Date(now - 60_000).toISOString(), temperature_c: 18.2, humidity_pct: 60 },
      { device_id: device, recorded_at: new Date(now - 60_000).toISOString(), temperature_c: 18.2, humidity_pct: 60 },
      { device_id: device, recorded_at: new Date(now + 86_400_000).toISOString(), temperature_c: 18 },
    ],
  });
  assertEquals(r.status, 200);
  assertEquals(r.body.accepted, 1);
  assertEquals(r.body.duplicates, 1);
  assertEquals(r.body.rejected[0].reason, "recorded_at_in_future");
});

Deno.test("delta sync over HTTP returns the user's changes", async () => {
  const r = await rpc(owner, "sync_changes", { p_since_ts: null, p_since_id: null, p_limit: 100 });
  assertEquals(r.status, 200);
  const entities = new Set((r.body as { entity: string }[]).map((x) => x.entity));
  assert(entities.has("horse") && entities.has("membership") && entities.has("sensor"));
});

Deno.test("my_permissions reflects the caller's context", async () => {
  const o = await rpc(owner, "my_permissions", { p_resource_type: "horse", p_resource_id: horseId });
  const v = await rpc(other, "my_permissions", { p_resource_type: "horse", p_resource_id: horseId });
  assert(o.body.includes("update"));
  assertEquals(v.body, ["read", "read_media"]);
});

Deno.test("anon can look up a public product passport by QR code", async () => {
  const r = await rpc(null, "product_passport", { p_qr_code: "LBX-SADDLE-0001" });
  assertEquals(r.status, 200);
  assertEquals(r.body.manufacturer, "Fictional Saddlery GmbH");
  assertEquals("owner_id" in r.body, false);
});

Deno.test("users cannot call service-role ops functions", async () => {
  const r = await rpc(owner, "outbox_claim", { p_worker: "evil" });
  assertEquals(r.status, 403);
});
