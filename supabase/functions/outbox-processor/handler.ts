import { sign, timingSafeEqual } from "../_shared/signature.ts";
import { errorResponse, json } from "../_shared/http.ts";

export interface OutboxMessage {
  id: number;
  topic: string;
  aggregate_type: string;
  aggregate_id: string;
  payload: Record<string, unknown>;
  attempts: number;
  created_at: string;
}

export interface OutboxStore {
  claim(worker: string, batch: number): Promise<OutboxMessage[]>;
  complete(id: number, worker: string): Promise<boolean>;
  /** Returns the new status: 'pending' (will retry with backoff) or 'dead'. */
  fail(id: number, worker: string, error: string): Promise<string>;
}

export type Deliver = (msg: OutboxMessage) => Promise<void>;

export interface RunSummary {
  claimed: number;
  delivered: number;
  retrying: number;
  dead: number;
}

/** Drain the outbox until it is empty or the time budget is spent. */
export async function drainOutbox(opts: {
  store: OutboxStore;
  deliver: Deliver;
  worker: string;
  batchSize?: number;
  timeBudgetMs?: number;
  now?: () => number;
}): Promise<RunSummary> {
  const now = opts.now ?? Date.now;
  const deadline = now() + (opts.timeBudgetMs ?? 20_000);
  const summary: RunSummary = { claimed: 0, delivered: 0, retrying: 0, dead: 0 };

  while (now() < deadline) {
    const batch = await opts.store.claim(opts.worker, opts.batchSize ?? 20);
    if (batch.length === 0) break;
    summary.claimed += batch.length;

    for (const msg of batch) {
      try {
        await opts.deliver(msg);
        await opts.store.complete(msg.id, opts.worker);
        summary.delivered++;
      } catch (err) {
        const reason = err instanceof Error ? err.message : String(err);
        const status = await opts.store.fail(msg.id, opts.worker, reason);
        if (status === "dead") summary.dead++;
        else summary.retrying++;
      }
    }
  }
  return summary;
}

/**
 * Delivers an outbox message as a signed webhook (same signature scheme the
 * webhook-receiver verifies). Non-2xx or timeout throws, which triggers retry.
 * The x-webhook-id is stable per message so the receiver can dedupe retries.
 */
export function createWebhookDeliverer(opts: {
  url: string;
  secret: string;
  fetch?: typeof fetch;
  now?: () => number;
  timeoutMs?: number;
}): Deliver {
  const doFetch = opts.fetch ?? fetch;
  const now = opts.now ?? Date.now;
  return async (msg) => {
    const body = JSON.stringify({
      id: `outbox-${msg.id}`,
      type: msg.topic,
      aggregate: { type: msg.aggregate_type, id: msg.aggregate_id },
      data: msg.payload,
      created_at: msg.created_at,
    });
    const id = `outbox-${msg.id}`;
    const ts = Math.floor(now() / 1000);
    const res = await doFetch(opts.url, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-webhook-id": id,
        "x-webhook-timestamp": String(ts),
        "x-webhook-signature": await sign(opts.secret, id, ts, body),
      },
      body,
      signal: AbortSignal.timeout(opts.timeoutMs ?? 10_000),
    });
    if (!res.ok) {
      await res.body?.cancel();
      throw new Error(`delivery failed: HTTP ${res.status}`);
    }
    await res.body?.cancel();
  };
}

/**
 * HTTP entry point. Triggered by a scheduler (pg_cron + pg_net, or a GitHub
 * scheduled workflow) with the shared secret in x-cron-secret.
 */
export function createOutboxHandler(opts: {
  cronSecret: string;
  store: OutboxStore;
  deliver: Deliver;
  worker: string;
  batchSize?: number;
  timeBudgetMs?: number;
}) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "method_not_allowed");
    const provided = req.headers.get("x-cron-secret") ?? "";
    if (!opts.cronSecret || !timingSafeEqual(provided, opts.cronSecret)) {
      return errorResponse(401, "unauthorized");
    }
    try {
      const summary = await drainOutbox(opts);
      return json(200, summary);
    } catch (err) {
      console.error("outbox run failed", err);
      return errorResponse(500, "outbox_error");
    }
  };
}
