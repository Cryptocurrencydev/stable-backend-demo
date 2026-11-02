import { assert, assertEquals } from "@std/assert";
import { verifySignature } from "../_shared/signature.ts";
import {
  createOutboxHandler,
  createWebhookDeliverer,
  drainOutbox,
  type OutboxMessage,
  type OutboxStore,
} from "./handler.ts";

const NOW = Date.UTC(2026, 10, 2, 12, 0, 0);

function msg(id: number, topic = "task.assigned"): OutboxMessage {
  return {
    id,
    topic,
    aggregate_type: "stable_task",
    aggregate_id: "00000000-0000-4000-8000-000000000001",
    payload: { title: "Muck out stall 3" },
    attempts: 1,
    created_at: new Date(NOW).toISOString(),
  };
}

/** Simulates the SQL claim/complete/fail semantics, incl. dead-lettering. */
function fakeStore(messages: OutboxMessage[], maxAttempts = 3) {
  const state = new Map(messages.map((m) => [m.id, { m, status: "pending", attempts: 0 }]));
  const store: OutboxStore = {
    claim(_worker, batch) {
      const out: OutboxMessage[] = [];
      for (const s of state.values()) {
        if (s.status === "pending" && out.length < batch) {
          s.status = "processing";
          s.attempts++;
          out.push({ ...s.m, attempts: s.attempts });
        }
      }
      return Promise.resolve(out);
    },
    complete(id) {
      state.get(id)!.status = "done";
      return Promise.resolve(true);
    },
    fail(id) {
      const s = state.get(id)!;
      // the real store applies a backoff via available_at; in the fake, a failed
      // message is parked until the next drain call
      s.status = s.attempts >= maxAttempts ? "dead" : "parked";
      return Promise.resolve(s.status === "dead" ? "dead" : "pending");
    },
  };
  const release = () => {
    for (const s of state.values()) if (s.status === "parked") s.status = "pending";
  };
  return { store, state, release };
}

Deno.test("drainOutbox delivers and completes every message", async () => {
  const { store, state } = fakeStore([msg(1), msg(2), msg(3)]);
  const delivered: number[] = [];
  const summary = await drainOutbox({
    store,
    worker: "w1",
    batchSize: 2,
    deliver: (m) => {
      delivered.push(m.id);
      return Promise.resolve();
    },
  });
  assertEquals(summary, { claimed: 3, delivered: 3, retrying: 0, dead: 0 });
  assertEquals(delivered, [1, 2, 3]);
  assert([...state.values()].every((s) => s.status === "done"));
});

Deno.test("failed delivery is retried on the next run and succeeds", async () => {
  const { store, state, release } = fakeStore([msg(1)]);
  let calls = 0;
  const deliver = () => (++calls === 1 ? Promise.reject(new Error("HTTP 503")) : Promise.resolve());

  const first = await drainOutbox({ store, deliver, worker: "w1" });
  assertEquals(first, { claimed: 1, delivered: 0, retrying: 1, dead: 0 });

  release(); // backoff elapsed
  const second = await drainOutbox({ store, deliver, worker: "w1" });
  assertEquals(second, { claimed: 1, delivered: 1, retrying: 0, dead: 0 });
  assertEquals(state.get(1)!.status, "done");
});

Deno.test("message is dead-lettered after max attempts", async () => {
  const { store, state, release } = fakeStore([msg(1)], 3);
  const deliver = () => Promise.reject(new Error("HTTP 500"));
  const totals = { retrying: 0, dead: 0 };
  for (let i = 0; i < 4; i++) {
    const s = await drainOutbox({ store, deliver, worker: "w1" });
    totals.retrying += s.retrying;
    totals.dead += s.dead;
    release();
  }
  assertEquals(totals, { retrying: 2, dead: 1 });
  assertEquals(state.get(1)!.status, "dead");
});

Deno.test("one failing message does not block the rest of the batch", async () => {
  const { store } = fakeStore([msg(1), msg(2), msg(3)]);
  const summary = await drainOutbox({
    store,
    worker: "w1",
    deliver: (m) => (m.id === 2 ? Promise.reject(new Error("boom")) : Promise.resolve()),
  });
  assertEquals(summary, { claimed: 3, delivered: 2, retrying: 1, dead: 0 });
});

Deno.test("time budget stops the drain loop", async () => {
  const { store } = fakeStore(Array.from({ length: 50 }, (_, i) => msg(i + 1)));
  let t = 0;
  const summary = await drainOutbox({
    store,
    worker: "w1",
    batchSize: 10,
    timeBudgetMs: 25,
    now: () => (t += 10),
    deliver: () => Promise.resolve(),
  });
  assert(summary.claimed < 50);
});

Deno.test("webhook deliverer signs requests the receiver can verify", async () => {
  let captured: Request | undefined;
  const deliver = createWebhookDeliverer({
    url: "https://partner.example.test/hooks",
    secret: "outbound_test_secret",
    now: () => NOW,
    fetch: (input, init) => {
      captured = new Request(input as string, init);
      return Promise.resolve(new Response("ok", { status: 200 }));
    },
  });
  await deliver(msg(42));
  const body = await captured!.text();
  const verdict = await verifySignature({
    secrets: ["outbound_test_secret"],
    id: captured!.headers.get("x-webhook-id"),
    timestamp: captured!.headers.get("x-webhook-timestamp"),
    signature: captured!.headers.get("x-webhook-signature"),
    body,
    nowMs: NOW,
  });
  assert(verdict.ok);
  assertEquals(captured!.headers.get("x-webhook-id"), "outbox-42");
  assertEquals(JSON.parse(body).type, "task.assigned");
});

Deno.test("webhook deliverer throws on non-2xx so the message is retried", async () => {
  const deliver = createWebhookDeliverer({
    url: "https://partner.example.test/hooks",
    secret: "s",
    fetch: () => Promise.resolve(new Response("nope", { status: 502 })),
  });
  let threw = false;
  try {
    await deliver(msg(1));
  } catch (e) {
    threw = true;
    assertEquals((e as Error).message, "delivery failed: HTTP 502");
  }
  assert(threw);
});

Deno.test("HTTP handler requires the cron secret", async () => {
  const { store } = fakeStore([msg(1)]);
  const h = createOutboxHandler({
    cronSecret: "cron_test_secret",
    store,
    deliver: () => Promise.resolve(),
    worker: "w",
  });
  const denied = await h(new Request("http://localhost/", { method: "POST", headers: { "x-cron-secret": "wrong" } }));
  assertEquals(denied.status, 401);
  const ok = await h(
    new Request("http://localhost/", { method: "POST", headers: { "x-cron-secret": "cron_test_secret" } }),
  );
  assertEquals(ok.status, 200);
  assertEquals((await ok.json()).delivered, 1);
});

Deno.test("HTTP handler refuses to run with an empty configured secret", async () => {
  const { store } = fakeStore([]);
  const h = createOutboxHandler({ cronSecret: "", store, deliver: () => Promise.resolve(), worker: "w" });
  const res = await h(new Request("http://localhost/", { method: "POST", headers: { "x-cron-secret": "" } }));
  assertEquals(res.status, 401);
});
