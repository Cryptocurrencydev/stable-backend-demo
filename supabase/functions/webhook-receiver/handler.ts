import { verifySignature } from "../_shared/signature.ts";
import { errorResponse, json, readBodyLimited } from "../_shared/http.ts";

export interface RecordInput {
  provider: string;
  eventId: string;
  eventType: string | null;
  payload: Record<string, unknown>;
  signedAt: Date;
}

export interface RecordResult {
  status: "recorded" | "duplicate";
  id: number;
}

export interface WebhookDeps {
  provider: string;
  /** Active secrets. More than one during rotation. */
  secrets: string[];
  record: (e: RecordInput) => Promise<RecordResult>;
  now?: () => number;
  toleranceSeconds?: number;
  maxBodyBytes?: number;
}

/**
 * Verifies a signed inbound webhook and records it idempotently.
 *
 *   405  not POST
 *   413  body too large
 *   400  missing headers / bad timestamp / stale or future timestamp / bad JSON
 *   401  signature mismatch
 *   200  { status: "recorded" | "duplicate" }   (duplicate = replay, safe to ack)
 *   500  storage failure (sender should retry; recording is idempotent)
 */
export function createWebhookHandler(deps: WebhookDeps) {
  const now = deps.now ?? Date.now;
  const maxBody = deps.maxBodyBytes ?? 256 * 1024;

  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "method_not_allowed");

    const body = await readBodyLimited(req, maxBody);
    if (body === null) return errorResponse(413, "payload_too_large");

    const id = req.headers.get("x-webhook-id");
    const verdict = await verifySignature({
      secrets: deps.secrets,
      id,
      timestamp: req.headers.get("x-webhook-timestamp"),
      signature: req.headers.get("x-webhook-signature"),
      body,
      nowMs: now(),
      toleranceSeconds: deps.toleranceSeconds,
    });
    if (!verdict.ok) return errorResponse(verdict.status, verdict.error);

    let payload: unknown;
    try {
      payload = JSON.parse(body);
    } catch {
      return errorResponse(400, "invalid_json");
    }
    if (typeof payload !== "object" || payload === null || Array.isArray(payload)) {
      return errorResponse(400, "invalid_payload");
    }
    const p = payload as Record<string, unknown>;

    try {
      const result = await deps.record({
        provider: deps.provider,
        eventId: id!,
        eventType: typeof p.type === "string" ? p.type : null,
        payload: p,
        signedAt: verdict.signedAt,
      });
      return json(200, result);
    } catch (err) {
      console.error("record_webhook_event failed", err);
      return errorResponse(500, "storage_error");
    }
  };
}
