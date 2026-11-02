import { assert, assertEquals } from "@std/assert";
import { hmacSha256Hex, sign, timingSafeEqual, verifySignature } from "./signature.ts";

const SECRET = "whsec_test_only_not_a_real_secret";
const NOW = Date.UTC(2026, 10, 2, 12, 0, 0);
const TS = String(NOW / 1000);
const BODY = JSON.stringify({ type: "device.offline", device_id: "SH-TEMP-0001" });

Deno.test("hmacSha256Hex matches a known RFC 4231 vector", async () => {
  // RFC 4231 test case 2
  assertEquals(
    await hmacSha256Hex("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  );
});

Deno.test("timingSafeEqual", () => {
  assert(timingSafeEqual("abc", "abc"));
  assert(!timingSafeEqual("abc", "abd"));
  assert(!timingSafeEqual("abc", "abcd"));
  assert(!timingSafeEqual("", "a"));
});

Deno.test("valid signature verifies", async () => {
  const signature = await sign(SECRET, "evt_1", Number(TS), BODY);
  const r = await verifySignature({ secrets: [SECRET], id: "evt_1", timestamp: TS, signature, body: BODY, nowMs: NOW });
  assert(r.ok);
  if (r.ok) assertEquals(r.signedAt.getTime(), NOW);
});

Deno.test("tampered body is rejected with 401", async () => {
  const signature = await sign(SECRET, "evt_1", Number(TS), BODY);
  const r = await verifySignature({
    secrets: [SECRET],
    id: "evt_1",
    timestamp: TS,
    signature,
    body: BODY.replace("offline", "online"),
    nowMs: NOW,
  });
  assertEquals(r, { ok: false, status: 401, error: "invalid_signature" });
});

Deno.test("signature bound to event id (cannot be reused for another id)", async () => {
  const signature = await sign(SECRET, "evt_1", Number(TS), BODY);
  const r = await verifySignature({ secrets: [SECRET], id: "evt_2", timestamp: TS, signature, body: BODY, nowMs: NOW });
  assertEquals(r.ok, false);
});

Deno.test("timestamp outside tolerance is rejected (replay of old request)", async () => {
  const old = Number(TS) - 301;
  const signature = await sign(SECRET, "evt_1", old, BODY);
  const r = await verifySignature({
    secrets: [SECRET],
    id: "evt_1",
    timestamp: String(old),
    signature,
    body: BODY,
    nowMs: NOW,
  });
  assertEquals(r, { ok: false, status: 400, error: "timestamp_out_of_tolerance" });
});

Deno.test("future timestamp outside tolerance is rejected", async () => {
  const future = Number(TS) + 301;
  const signature = await sign(SECRET, "evt_1", future, BODY);
  const r = await verifySignature({
    secrets: [SECRET],
    id: "evt_1",
    timestamp: String(future),
    signature,
    body: BODY,
    nowMs: NOW,
  });
  assertEquals(r.ok, false);
});

Deno.test("timestamp at the tolerance edge is accepted", async () => {
  const edge = Number(TS) - 300;
  const signature = await sign(SECRET, "evt_1", edge, BODY);
  const r = await verifySignature({
    secrets: [SECRET],
    id: "evt_1",
    timestamp: String(edge),
    signature,
    body: BODY,
    nowMs: NOW,
  });
  assert(r.ok);
});

Deno.test("secret rotation: either active secret verifies", async () => {
  const signature = await sign("old_secret", "evt_1", Number(TS), BODY);
  const r = await verifySignature({
    secrets: ["new_secret", "old_secret"],
    id: "evt_1",
    timestamp: TS,
    signature,
    body: BODY,
    nowMs: NOW,
  });
  assert(r.ok);
});

Deno.test("multiple signatures in header: any valid one passes", async () => {
  const good = await sign(SECRET, "evt_1", Number(TS), BODY);
  const r = await verifySignature({
    secrets: [SECRET],
    id: "evt_1",
    timestamp: TS,
    signature: `v1=deadbeef ${good}`,
    body: BODY,
    nowMs: NOW,
  });
  assert(r.ok);
});

Deno.test("missing headers / malformed timestamp / no secrets", async () => {
  const base = { secrets: [SECRET], id: "evt_1", timestamp: TS, signature: "v1=00", body: BODY, nowMs: NOW };
  assertEquals((await verifySignature({ ...base, id: null })).ok, false);
  assertEquals(await verifySignature({ ...base, timestamp: "yesterday" }), {
    ok: false,
    status: 400,
    error: "invalid_timestamp",
  });
  assertEquals(await verifySignature({ ...base, signature: "sha256=abc" }), {
    ok: false,
    status: 401,
    error: "invalid_signature",
  });
  assertEquals(await verifySignature({ ...base, secrets: [] }), {
    ok: false,
    status: 401,
    error: "invalid_signature",
  });
});
