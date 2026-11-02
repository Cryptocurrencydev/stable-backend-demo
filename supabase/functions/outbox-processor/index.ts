// Outbox processor. verify_jwt = false in config.toml; protected by
// OUTBOX_CRON_SECRET instead (called by a scheduler, not by users).
import { createClient } from "@supabase/supabase-js";
import { createOutboxHandler, createWebhookDeliverer, type Deliver, type OutboxStore } from "./handler.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "api" }, auth: { persistSession: false } },
);

const store: OutboxStore = {
  async claim(worker, batch) {
    const { data, error } = await supabase.rpc("outbox_claim", { p_worker: worker, p_batch: batch });
    if (error) throw error;
    return data ?? [];
  },
  async complete(id, worker) {
    const { data, error } = await supabase.rpc("outbox_complete", { p_id: id, p_worker: worker });
    if (error) throw error;
    return data;
  },
  async fail(id, worker, reason) {
    const { data, error } = await supabase.rpc("outbox_fail", { p_id: id, p_worker: worker, p_error: reason });
    if (error) throw error;
    return data;
  },
};

const targetUrl = Deno.env.get("OUTBOX_TARGET_URL");
const deliver: Deliver = targetUrl
  ? createWebhookDeliverer({ url: targetUrl, secret: Deno.env.get("OUTBOX_SIGNING_SECRET") ?? "" })
  : (msg) => {
    // No target configured (local dev): log and acknowledge.
    console.log(`[outbox dry-run] #${msg.id} ${msg.topic}`, msg.payload);
    return Promise.resolve();
  };

Deno.serve(createOutboxHandler({
  cronSecret: Deno.env.get("OUTBOX_CRON_SECRET") ?? "",
  store,
  deliver,
  worker: `edge-${crypto.randomUUID().slice(0, 8)}`,
}));
