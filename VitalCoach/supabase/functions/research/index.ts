// Supabase Edge Function: VitalCoach research (Compound Insight Cards, proactive discovery,
// followed research interests and update alerts).
//
// Security & privacy
// - Requires the user's Supabase JWT; identity is verified with auth.getUser() (401 otherwise).
// - Reads the user's records with a *user-scoped* client (RLS); writes cards, interests and
//   alerts with the service role, setting user_id from the verified token.
// - Outbound research requests (PubMed, ClinicalTrials.gov, openFDA) carry only sanitized
//   compound/topic terms — never user identifiers or health values. Responses are cached in the
//   shared, service-only research_cache table (7-day TTL).
// - AI calls reuse the coach's ai_config model, budgets and record_ai_usage, and require AI consent.
// - Logs contain status codes only.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handle, type Interest, type ResearchDb, type ResearchRequest, type StoredAlert, type StoredInsight } from "./lib/handler.ts";
import type { ResearchCache } from "./lib/sources.ts";
import { callModel, type ModelConfig } from "../coach/lib/openai.ts";
import { adminKey, aiConsentGranted, loadRows, must, publicKey } from "../coach/shared_db.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type" };
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

function makeCache(admin: SupabaseClient): ResearchCache {
  return {
    async get(key, maxAgeMs, now) {
      const r = await admin.from("research_cache").select("payload, fetched_at").eq("cache_key", key)
        .gte("fetched_at", new Date(now.getTime() - maxAgeMs).toISOString()).maybeSingle();
      if (r.error) return null; // a cache failure only costs an extra API call
      return r.data as any;
    },
    async put(key, source, query, payload, fetchedAt) {
      await admin.from("research_cache").upsert({ cache_key: key, source, query: query.slice(0, 200), payload, fetched_at: fetchedAt }, { onConflict: "cache_key" });
    },
  };
}

const INTEREST_COLS = "id, kind, term, display_name, created_at, last_checked_at, last_seen";

function makeDb(user: SupabaseClient, admin: SupabaseClient): ResearchDb {
  return {
    aiConsentGranted: () => aiConsentGranted(user),
    loadRows: (_today: string) => loadRows(user),

    async config(): Promise<ModelConfig> {
      return must(await admin.from("ai_config").select("*").eq("is_active", true).single(), "config") as ModelConfig;
    },

    async usage(uid, utcDay, month, sinceIso) {
      const [today, monthTotal, recent] = await Promise.all([
        admin.from("ai_usage").select("requests, input_tokens, output_tokens").eq("user_id", uid).eq("usage_date", utcDay).maybeSingle(),
        admin.rpc("ai_usage_month_total", { p_month_start: month }),
        admin.from("compound_insights").select("id", { count: "exact", head: true }).eq("user_id", uid).gte("created_at", sinceIso),
      ]);
      const t = must(today, "usage") as any;
      return {
        userTokensToday: t ? Number(t.input_tokens) + Number(t.output_tokens) : 0,
        userRequestsToday: t ? Number(t.requests) : 0,
        userRequestsLastMinute: recent.count ?? 0,
        globalTokensThisMonth: Number(must(monthTotal, "month_total") ?? 0),
      };
    },

    async recordUsage(uid, utcDay, input, output) {
      must(await admin.rpc("record_ai_usage", { p_user: uid, p_date: utcDay, p_input: input, p_output: output }), "record_usage");
    },

    async findInsight(uid, kind, key, hash, sinceIso) {
      const r = await admin.from("compound_insights").select("id, kind, compound_key, context_hash, payload, created_at")
        .eq("user_id", uid).eq("kind", kind).eq("compound_key", key).eq("context_hash", hash).gte("created_at", sinceIso)
        .order("created_at", { ascending: false }).limit(1);
      return ((must(r, "find_insight") as any[])[0] ?? null) as StoredInsight | null;
    },

    async saveInsight(uid, row) {
      // Keep one row per (user, kind, compound, context): replace older versions.
      await admin.from("compound_insights").delete().eq("user_id", uid).eq("kind", row.kind).eq("compound_key", row.compound_key).eq("context_hash", row.context_hash);
      const r = await admin.from("compound_insights").insert({ user_id: uid, ...row }).select("id, kind, compound_key, context_hash, payload, created_at").single();
      return must(r, "save_insight") as StoredInsight;
    },

    async listInterests(uid) {
      const r = await admin.from("research_interests").select(INTEREST_COLS).eq("user_id", uid).order("created_at");
      return must(r, "interests") as Interest[];
    },

    async addInterest(uid, row) {
      const r = await admin.from("research_interests").insert({ user_id: uid, ...row }).select(INTEREST_COLS).single();
      return must(r, "add_interest") as Interest;
    },

    async removeInterest(uid, id) {
      const r = await admin.from("research_interests").delete().eq("user_id", uid).eq("id", id).select("id");
      return (must(r, "remove_interest") as any[]).length > 0;
    },

    async updateInterest(uid, id, lastSeen, checkedAt) {
      must(await admin.from("research_interests").update({ last_seen: lastSeen, last_checked_at: checkedAt }).eq("user_id", uid).eq("id", id), "update_interest");
    },

    async saveAlerts(uid, interestId, drafts) {
      const rows = drafts.map((d) => ({ user_id: uid, interest_id: interestId, kind: d.kind, title: d.title.slice(0, 200), summary: d.summary, citation: d.citation, citation_id: d.citation.id }));
      const r = await admin.from("research_alerts").upsert(rows, { onConflict: "interest_id,kind,citation_id", ignoreDuplicates: true })
        .select("id, interest_id, kind, title, summary, citation, created_at, seen_at");
      return must(r, "save_alerts") as StoredAlert[];
    },
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!jwt) return json(401, { error: "missing_token" });

  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = adminKey();
  const anonKey = publicKey();
  if (!serviceKey || !anonKey) return json(500, { error: "server_misconfigured" });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: who, error: whoError } = await admin.auth.getUser(jwt);
  if (whoError || !who?.user) return json(401, { error: "invalid_token" });
  const userId = who.user.id;

  let body: ResearchRequest;
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }

  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!openaiKey && (body?.op === "insight_card" || body?.op === "discover")) {
    return json(503, { error: "coach_not_configured", message: "Research summaries aren't set up yet (missing AI provider key)." });
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });

  try {
    const result = await handle(body, userId, {
      db: makeDb(userClient, admin),
      cache: makeCache(admin),
      fetch: (u, init) => fetch(u, init),
      model: (b) => callModel(openaiKey ?? "", b, fetch, 90_000),
      now: () => new Date(),
      ncbiApiKey: Deno.env.get("NCBI_API_KEY") || undefined,
    });
    if (result.status >= 400) console.warn("research", { op: body?.op, status: result.status, code: result.body.error });
    return json(result.status, result.body);
  } catch (e) {
    console.error("research failure", { op: body?.op, kind: (e as Error)?.message?.split(":")[0] ?? "unknown" });
    return json(500, { error: "internal", message: "Something went wrong. Please try again." });
  }
});
