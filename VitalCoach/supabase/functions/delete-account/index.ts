// Supabase Edge Function: permanently deletes the calling user's account.
//
// The function verifies the caller's token itself (auth.getUser), so it works whether or not
// the gateway's "Verify JWT" setting is on — which matters with Supabase's newer JWT signing keys.
//
// Flow: verify the caller's JWT → delete their progress-photo objects (none in Phase 1, but the
// bucket prefix is cleared defensively) → delete the auth user with the service-role key.
// All public.* rows reference auth.users ON DELETE CASCADE, so they are removed in the same
// operation. The service-role key is injected by Supabase as an environment secret and never
// leaves the server.
//
// NOTE: written against the documented supabase-js v2 API; it has not been executed in this
// repository's CI (no Deno runtime). Verify with `supabase functions serve` before release.
import { createClient } from "jsr:@supabase/supabase-js@2";

// Prefer the new secret API keys (SUPABASE_SECRET_KEYS is a JSON object such as
// {"default": "sb_secret_..."}); fall back to the deprecated legacy service-role key.
function adminKey(): string | undefined {
  const raw = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (raw) {
    try {
      const keys = JSON.parse(raw) as Record<string, string>;
      const key = keys["default"] ?? Object.values(keys)[0];
      if (key) return key;
    } catch { /* fall through */ }
  }
  return Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? undefined;
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const authHeader = req.headers.get("Authorization") ?? "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "");
  if (!jwt) return json(401, { error: "missing_token" });

  let body: { confirm?: boolean } = {};
  try { body = await req.json(); } catch { /* empty body */ }
  if (body.confirm !== true) return json(400, { error: "confirmation_required" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = adminKey();
  if (!serviceKey) return json(500, { error: "server_misconfigured" });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  const { data: userData, error: userError } = await admin.auth.getUser(jwt);
  if (userError || !userData?.user) return json(401, { error: "invalid_token" });
  const userId = userData.user.id;

  // Remove private storage objects under the user's prefix (bucket created in a later phase).
  const { data: objects } = await admin.storage.from("progress-photos").list(userId, { limit: 1000 });
  if (objects && objects.length > 0) {
    await admin.storage.from("progress-photos").remove(objects.map((o) => `${userId}/${o.name}`));
  }

  const { error } = await admin.auth.admin.deleteUser(userId);
  if (error) {
    console.error("delete-account failed", { code: error.status }); // never log user data
    return json(500, { error: "delete_failed" });
  }
  return json(200, { deleted: true });
});
