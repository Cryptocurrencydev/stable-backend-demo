// HMAC-SHA256 webhook signatures (Web Crypto only, no dependencies).
//
// Wire format, used for both inbound (webhook-receiver) and outbound
// (outbox-processor) webhooks:
//
//   x-webhook-id:         unique event id (replay key)
//   x-webhook-timestamp:  unix seconds when the sender signed
//   x-webhook-signature:  v1=<hex> [v1=<hex> ...]   (several during key rotation)
//
//   signed content = `${id}.${timestamp}.${rawBody}`

const encoder = new TextEncoder();

export const DEFAULT_TOLERANCE_SECONDS = 300;

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(message));
  return Array.from(new Uint8Array(sig), (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Constant-time comparison so attackers cannot learn a signature byte by byte. */
export function timingSafeEqual(a: string, b: string): boolean {
  const ab = encoder.encode(a);
  const bb = encoder.encode(b);
  let diff = ab.length ^ bb.length;
  const len = Math.max(ab.length, bb.length);
  for (let i = 0; i < len; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}

export async function sign(
  secret: string,
  id: string,
  timestamp: number,
  body: string,
): Promise<string> {
  return `v1=${await hmacSha256Hex(secret, `${id}.${timestamp}.${body}`)}`;
}

export type VerifyResult =
  | { ok: true; signedAt: Date }
  | { ok: false; status: 400 | 401; error: string };

export interface VerifyInput {
  secrets: string[];
  id: string | null;
  timestamp: string | null;
  signature: string | null;
  body: string;
  nowMs: number;
  toleranceSeconds?: number;
}

export async function verifySignature(input: VerifyInput): Promise<VerifyResult> {
  const { secrets, id, timestamp, signature, body, nowMs } = input;
  const tolerance = input.toleranceSeconds ?? DEFAULT_TOLERANCE_SECONDS;

  if (!id || !timestamp || !signature) {
    return { ok: false, status: 400, error: "missing_signature_headers" };
  }
  if (!/^\d{9,11}$/.test(timestamp)) {
    return { ok: false, status: 400, error: "invalid_timestamp" };
  }
  const ts = Number(timestamp);
  if (Math.abs(nowMs / 1000 - ts) > tolerance) {
    // Stale or far-future: rejects replays of old captured requests.
    return { ok: false, status: 400, error: "timestamp_out_of_tolerance" };
  }
  if (secrets.length === 0) {
    return { ok: false, status: 401, error: "invalid_signature" };
  }

  const provided = signature
    .split(/\s+/)
    .filter((p) => p.startsWith("v1="))
    .map((p) => p.slice(3));
  if (provided.length === 0) {
    return { ok: false, status: 401, error: "invalid_signature" };
  }

  const content = `${id}.${timestamp}.${body}`;
  for (const secret of secrets) {
    const expected = await hmacSha256Hex(secret, content);
    // compare against every candidate without short-circuiting on the first byte
    let match = false;
    for (const p of provided) match = timingSafeEqual(expected, p) || match;
    if (match) return { ok: true, signedAt: new Date(ts * 1000) };
  }
  return { ok: false, status: 401, error: "invalid_signature" };
}
