import { assertEquals } from "@std/assert";
import { createMediaHandler, isSafeObjectPath, type MediaDeps } from "./handler.ts";

const HORSE_A = "a0000000-0000-4000-8000-000000000001";
const HORSE_B = "b0000000-0000-4000-8000-000000000002";

// jwt -> horse -> permissions, mimicking api.my_permissions per caller
const PERMS: Record<string, Record<string, string[]>> = {
  "jwt-owner": { [HORSE_A]: ["read", "read_media", "write_media", "update"] },
  "jwt-viewer": { [HORSE_A]: ["read", "read_media"] },
  "jwt-stranger": {},
};

function deps(signed: string[] = []): MediaDeps {
  return {
    getPermissions: (jwt, horse) => Promise.resolve(jwt in PERMS ? (PERMS[jwt][horse] ?? []) : null),
    signDownload: (path, ttl) => {
      signed.push(path);
      return Promise.resolve(`https://storage.example.test/sign/${path}?ttl=${ttl}`);
    },
    signUpload: (path) => {
      signed.push(path);
      return Promise.resolve({ signedUrl: `https://storage.example.test/upload/${path}`, token: "upload-token" });
    },
  };
}

function req(jwt: string | null, body: unknown, method = "POST") {
  return new Request("http://localhost/horse-media-url", {
    method,
    headers: jwt ? { authorization: `Bearer ${jwt}`, "content-type": "application/json" } : {},
    body: method === "POST" ? JSON.stringify(body) : undefined,
  });
}

Deno.test("owner gets a signed download URL scoped to the horse folder", async () => {
  const signed: string[] = [];
  const res = await createMediaHandler(deps(signed))(req("jwt-owner", { horse_id: HORSE_A, path: "photos/front.jpg" }));
  assertEquals(res.status, 200);
  const body = await res.json();
  assertEquals(body.path, `${HORSE_A}/photos/front.jpg`);
  assertEquals(body.expires_in, 300);
  assertEquals(signed, [`${HORSE_A}/photos/front.jpg`]);
});

Deno.test("viewer can download but not upload", async () => {
  const h = createMediaHandler(deps());
  assertEquals((await h(req("jwt-viewer", { horse_id: HORSE_A, path: "a.jpg" }))).status, 200);
  const up = await h(req("jwt-viewer", { horse_id: HORSE_A, path: "a.jpg", mode: "upload" }));
  assertEquals(up.status, 403);
  assertEquals((await up.json()).code, "forbidden");
});

Deno.test("owner can get an upload URL", async () => {
  const res = await createMediaHandler(deps())(
    req("jwt-owner", { horse_id: HORSE_A, path: "vet/xray.pdf", mode: "upload" }),
  );
  assertEquals(res.status, 200);
  assertEquals((await res.json()).token, "upload-token");
});

Deno.test("stranger gets 404 (no existence leak) and nothing is signed", async () => {
  const signed: string[] = [];
  const res = await createMediaHandler(deps(signed))(req("jwt-stranger", { horse_id: HORSE_A, path: "a.jpg" }));
  assertEquals(res.status, 404);
  assertEquals(signed.length, 0);
});

Deno.test("owner of horse A cannot get URLs for horse B", async () => {
  const signed: string[] = [];
  const res = await createMediaHandler(deps(signed))(req("jwt-owner", { horse_id: HORSE_B, path: "a.jpg" }));
  assertEquals(res.status, 404);
  assertEquals(signed.length, 0);
});

Deno.test("path traversal cannot escape the horse folder", async () => {
  const h = createMediaHandler(deps());
  for (const path of ["../" + HORSE_B + "/a.jpg", "a/../../b.jpg", "/etc/passwd", "a\\b.jpg", "", ".hidden", "a//b"]) {
    const res = await h(req("jwt-owner", { horse_id: HORSE_A, path }));
    assertEquals(res.status, 400, `path ${JSON.stringify(path)} should be rejected`);
  }
});

Deno.test("missing JWT -> 401, invalid JWT -> 401", async () => {
  const h = createMediaHandler(deps());
  assertEquals((await h(req(null, { horse_id: HORSE_A, path: "a.jpg" }))).status, 401);
  assertEquals((await h(req("jwt-forged", { horse_id: HORSE_A, path: "a.jpg" }))).status, 401);
});

Deno.test("invalid input -> 400, wrong method -> 405", async () => {
  const h = createMediaHandler(deps());
  assertEquals((await h(req("jwt-owner", { horse_id: "not-a-uuid", path: "a.jpg" }))).status, 400);
  assertEquals((await h(req("jwt-owner", { horse_id: HORSE_A, path: "a.jpg", mode: "delete" }))).status, 400);
  assertEquals((await h(req("jwt-owner", null, "GET"))).status, 405);
});

Deno.test("isSafeObjectPath", () => {
  assertEquals(isSafeObjectPath("photos/2026/front.jpg"), true);
  assertEquals(isSafeObjectPath("a/../b"), false);
  assertEquals(isSafeObjectPath(42), false);
});
