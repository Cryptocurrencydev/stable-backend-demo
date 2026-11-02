import { assertEquals } from "@std/assert";
import { sign } from "../_shared/signature.ts";
import { createWebhookHandler, type RecordInput, type RecordResult } from "./handler.ts";

const SECRET = "whsec_test_only_not_a_real_secret";
const NOW = Date.UTC(2026, 10, 2, 12, 0, 0);

/** In-memory stand-in for api.record_webhook_event with the same unique key. */
function fakeStore() {
  const seen = new Map<string, number>();
  const calls: RecordInput[] = [];
  return {
    calls,
    record(e: RecordInput): Promise<RecordResult> {
      calls.push(e);
      const key = `${e.provider}:${e.eventId}`;
      if (seen.has(key)) return Promise.resolve({ status: "duplicate", id: seen.get(key)! });
      seen.set(key, seen.size + 1);
      return Promise.resolve({ status: "recorded", id: seen.size });
    },
  };
}

async function signedRequest(
  { id = "evt_100", body = '{"type":"device.offline","device_id":"SH-TEMP-0001"}', ts = NOW / 1000, secret = SECRET } =
    {},
) {
  return new Request("http://localhost/webhook-receiver", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-webhook-id": id,
      "x-webhook-timestamp": String(ts),
      "x-webhook-signature": await sign(secret, id, ts, body),
    },
    body,
  });
}

function handler(store = fakeStore()) {
  return {
    store,
    h: createWebhookHandler({ provider: "sensorhub", secrets: [SECRET], record: store.record, now: () => NOW }),
  };
}

Deno.test("valid webhook is recorded", async () => {
  const { h, store } = handler();
  const res = await h(await signedRequest());
  assertEquals(res.status, 200);
  assertEquals(await res.json(), { status: "recorded", id: 1 });
  assertEquals(store.calls[0].eventType, "device.offline");
  assertEquals(store.calls[0].signedAt.getTime(), NOW);
});

Deno.test("replayed webhook (same id) is acknowledged as duplicate, not re-processed", async () => {
  const { h } = handler();
  await h(await signedRequest());
  const res = await h(await signedRequest());
  assertEquals(res.status, 200);
  assertEquals((await res.json()).status, "duplicate");
});

Deno.test("wrong secret -> 401 and nothing recorded", async () => {
  const { h, store } = handler();
  const res = await h(await signedRequest({ secret: "attacker" }));
  assertEquals(res.status, 401);
  assertEquals((await res.json()).code, "invalid_signature");
  assertEquals(store.calls.length, 0);
});

Deno.test("stale timestamp -> 400 and nothing recorded", async () => {
  const { h, store } = handler();
  const res = await h(await signedRequest({ ts: NOW / 1000 - 3600 }));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).code, "timestamp_out_of_tolerance");
  assertEquals(store.calls.length, 0);
});

Deno.test("missing signature headers -> 400", async () => {
  const { h } = handler();
  const res = await h(new Request("http://localhost/", { method: "POST", body: "{}" }));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).code, "missing_signature_headers");
});

Deno.test("non-POST -> 405", async () => {
  const { h } = handler();
  assertEquals((await h(new Request("http://localhost/", { method: "GET" }))).status, 405);
});

Deno.test("validly signed but non-object JSON -> 400", async () => {
  const { h } = handler();
  const res = await h(await signedRequest({ body: "[1,2,3]" }));
  assertEquals(res.status, 400);
  assertEquals((await res.json()).code, "invalid_payload");
});

Deno.test("oversized body -> 413", async () => {
  const store = fakeStore();
  const h = createWebhookHandler({
    provider: "sensorhub",
    secrets: [SECRET],
    record: store.record,
    now: () => NOW,
    maxBodyBytes: 10,
  });
  const res = await h(await signedRequest());
  assertEquals(res.status, 413);
});

Deno.test("storage failure -> 500 so the sender retries", async () => {
  const h = createWebhookHandler({
    provider: "sensorhub",
    secrets: [SECRET],
    now: () => NOW,
    record: () => Promise.reject(new Error("db down")),
  });
  const res = await h(await signedRequest());
  assertEquals(res.status, 500);
});
