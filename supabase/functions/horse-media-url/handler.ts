import { bearerToken, errorResponse, json, UUID_RE } from "../_shared/http.ts";

export const BUCKET = "horse-media";
export const DOWNLOAD_TTL_SECONDS = 300;

// one or more safe segments, no "..", no leading slash, no backslashes
const PATH_RE = /^[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}(\/[A-Za-z0-9_-][A-Za-z0-9._-]{0,99}){0,4}$/;

export function isSafeObjectPath(path: unknown): path is string {
  return typeof path === "string" && PATH_RE.test(path) && !path.split("/").includes("..");
}

export interface MediaDeps {
  /**
   * The caller's permissions on the horse, evaluated by app.has_permission via
   * api.my_permissions using the CALLER's JWT. null = JWT rejected.
   */
  getPermissions(jwt: string, horseId: string): Promise<string[] | null>;
  signDownload(objectPath: string, expiresIn: number): Promise<string>;
  signUpload(objectPath: string): Promise<{ signedUrl: string; token: string }>;
}

/**
 * POST { horse_id, path, mode?: "download" | "upload" }
 *   401 no / invalid JWT
 *   400 invalid body, horse_id or path
 *   404 caller cannot see the horse (no existence leak)
 *   403 caller can see the horse but lacks read_media / write_media
 *   200 { signed_url, path, expires_in, token? }
 */
export function createMediaHandler(deps: MediaDeps) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return errorResponse(405, "method_not_allowed");
    const jwt = bearerToken(req);
    if (!jwt) return errorResponse(401, "unauthenticated");

    let body: Record<string, unknown>;
    try {
      body = await req.json();
    } catch {
      return errorResponse(400, "invalid_json");
    }
    const horseId = body?.horse_id;
    const path = body?.path;
    const mode = body?.mode ?? "download";
    if (typeof horseId !== "string" || !UUID_RE.test(horseId)) return errorResponse(400, "invalid_horse_id");
    if (!isSafeObjectPath(path)) return errorResponse(400, "invalid_path");
    if (mode !== "download" && mode !== "upload") return errorResponse(400, "invalid_mode");

    const perms = await deps.getPermissions(jwt, horseId);
    if (perms === null) return errorResponse(401, "unauthenticated");
    if (!perms.includes("read")) return errorResponse(404, "not_found", "horse not found");

    const needed = mode === "upload" ? "write_media" : "read_media";
    if (!perms.includes(needed)) return errorResponse(403, "forbidden", `missing permission ${needed}`);

    // Objects are always namespaced by horse id, so a permission on horse A can
    // never produce a URL for an object of horse B.
    const objectPath = `${horseId}/${path}`;
    if (mode === "upload") {
      const { signedUrl, token } = await deps.signUpload(objectPath);
      return json(200, { signed_url: signedUrl, token, path: objectPath, bucket: BUCKET });
    }
    const signedUrl = await deps.signDownload(objectPath, DOWNLOAD_TTL_SECONDS);
    return json(200, { signed_url: signedUrl, path: objectPath, bucket: BUCKET, expires_in: DOWNLOAD_TTL_SECONDS });
  };
}
