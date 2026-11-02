// Inbound webhook endpoint (e.g. a sensor-hub vendor posting device events).
// verify_jwt = false in config.toml: the caller is an external system that
// authenticates with an HMAC signature instead of a Supabase JWT.
import { createClient } from "@supabase/supabase-js";
import { createWebhookHandler } from "./handler.ts";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { db: { schema: "api" }, auth: { persistSession: false } },
);

Deno.serve(createWebhookHandler({
  provider: Deno.env.get("WEBHOOK_PROVIDER") ?? "sensorhub",
  secrets: (Deno.env.get("WEBHOOK_SECRETS") ?? "").split(",").map((s) => s.trim()).filter(Boolean),
  record: async (e) => {
    const { data, error } = await supabase.rpc("record_webhook_event", {
      p_provider: e.provider,
      p_event_id: e.eventId,
      p_event_type: e.eventType,
      p_payload: e.payload,
      p_signed_at: e.signedAt.toISOString(),
    });
    if (error) throw error;
    return data;
  },
}));
