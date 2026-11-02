// Returns a short-lived signed storage URL for a horse's media, only if the
// caller holds read_media (download) or write_media (upload) on that horse.
// verify_jwt = true: the platform rejects requests without a valid user JWT.
import { createClient } from "@supabase/supabase-js";
import { BUCKET, createMediaHandler } from "./handler.ts";

const url = Deno.env.get("SUPABASE_URL")!;
const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

Deno.serve(createMediaHandler({
  async getPermissions(jwt, horseId) {
    // Permission check runs as the CALLER, through the same app.has_permission
    // used by RLS. The service key is only used after this succeeds.
    const asUser = createClient(url, anonKey, {
      db: { schema: "api" },
      auth: { persistSession: false },
      global: { headers: { Authorization: `Bearer ${jwt}` } },
    });
    const { data, error } = await asUser.rpc("my_permissions", {
      p_resource_type: "horse",
      p_resource_id: horseId,
    });
    if (error) {
      if (error.code === "PGRST301" || error.code === "PGRST302") return null;
      throw error;
    }
    return data ?? [];
  },
  async signDownload(objectPath, expiresIn) {
    const { data, error } = await admin.storage.from(BUCKET).createSignedUrl(objectPath, expiresIn);
    if (error) throw error;
    return data.signedUrl;
  },
  async signUpload(objectPath) {
    const { data, error } = await admin.storage.from(BUCKET).createSignedUploadUrl(objectPath);
    if (error) throw error;
    return { signedUrl: data.signedUrl, token: data.token };
  },
}));
