// Supabase Edge Function: VitalCoach AI coach.
//
// Security
// - Requires the user's Supabase JWT; identity is verified with auth.getUser().
// - Reads the user's health records with a *user-scoped* client, so Row Level Security limits
//   retrieval to that user's own rows.
// - Writes coach messages/insights/usage with the service role, setting user_id from the
//   verified token (clients cannot write these tables).
// - OPENAI_API_KEY lives only in Supabase Edge Function secrets.
// - Logs contain status codes only — never prompts, replies or health data.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { handle, type CoachRequest, type Db, type Insight } from "./lib/handler.ts";
import { callModel, type ModelConfig } from "./lib/openai.ts";
import { adminKey, aiConsentGranted, loadRows, must, publicKey } from "./shared_db.ts";

const CORS = { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "authorization, apikey, content-type" };
const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...CORS } });

function makeDb(user: SupabaseClient, admin: SupabaseClient, _userId: string): Db {
  return {
    aiConsentGranted: () => aiConsentGranted(user),
    loadRows: (_today: string) => loadRows(user),

    async config(): Promise<ModelConfig> {
      const r = await admin.from("ai_config").select("*").eq("is_active", true).single();
      return must(r, "config") as ModelConfig;
    },

    async usage(uid, utcDay, month, sinceIso) {
      const [today, monthTotal, recent] = await Promise.all([
        admin.from("ai_usage").select("requests, input_tokens, output_tokens").eq("user_id", uid).eq("usage_date", utcDay).maybeSingle(),
        admin.rpc("ai_usage_month_total", { p_month_start: month }),
        admin.from("coach_messages").select("id", { count: "exact", head: true }).eq("user_id", uid).eq("role", "user").gte("created_at", sinceIso),
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

    async findInsight(uid, kind, forDate) {
      const r = await admin.from("generated_insights").select("*").eq("user_id", uid).eq("kind", kind).eq("for_date", forDate).maybeSingle();
      return must(r, "find_insight") as Insight | null;
    },

    async saveInsight(uid, i, model, promptVersion) {
      const row = { user_id: uid, ...i, model, prompt_version: promptVersion, status: "new" };
      const periodic = i.kind === "morning_briefing" || i.kind === "weekly_summary";
      if (periodic) {
        await admin.from("generated_insights").delete().eq("user_id", uid).eq("kind", i.kind).eq("for_date", i.for_date);
      }
      return must(await admin.from("generated_insights").insert(row).select().single(), "save_insight") as Insight;
    },

    async conversation(uid, id, kind, title) {
      if (id) {
        const r = await admin.from("coach_conversations").select("id").eq("id", id).eq("user_id", uid).maybeSingle();
        if (must(r, "conversation")) {
          await admin.from("coach_conversations").update({ updated_at: new Date().toISOString() }).eq("id", id);
          return id;
        }
      }
      const r = await admin.from("coach_conversations").insert({ user_id: uid, kind, title: title || "Conversation" }).select("id").single();
      return (must(r, "new_conversation") as any).id;
    },

    async history(conversationId, limit) {
      const r = await admin.from("coach_messages").select("role, content").eq("conversation_id", conversationId)
        .in("role", ["user", "assistant"]).order("created_at", { ascending: false }).limit(limit);
      return (must(r, "history") as any[]).reverse();
    },

    async saveMessage(uid, m, extra) {
      const r = await admin.from("coach_messages").insert({ user_id: uid, ...m, ...(extra ?? {}) })
        .select("id, conversation_id, role, content, metadata, created_at").single();
      return must(r, "save_message") as any;
    },

    async proposeMemories(uid, messageId, memories) {
      const rows = memories.map((m) => ({ user_id: uid, category: m.category, content: m.content, source: "coach", status: "proposed", source_message_id: messageId }));
      must(await admin.from("coach_memory").insert(rows), "propose_memories");
      return rows.length;
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
  const openaiKey = Deno.env.get("OPENAI_API_KEY");
  if (!serviceKey || !anonKey) return json(500, { error: "server_misconfigured" });
  if (!openaiKey) return json(503, { error: "coach_not_configured", message: "The coach isn't set up yet (missing AI provider key)." });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
  const { data: who, error: whoError } = await admin.auth.getUser(jwt);
  if (whoError || !who?.user) return json(401, { error: "invalid_token" });
  const userId = who.user.id;

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${jwt}` } },
  });

  let body: CoachRequest;
  try { body = await req.json(); } catch { return json(400, { error: "bad_json" }); }

  try {
    const result = await handle(body, userId, {
      db: makeDb(userClient, admin, userId),
      model: (b) => callModel(openaiKey, b),
      now: () => new Date(),
    });
    if (result.status >= 400) console.warn("coach", { status: result.status, code: result.body.error });
    return json(result.status, result.body);
  } catch (e) {
    console.error("coach failure", { kind: (e as Error)?.message?.split(":")[0] ?? "unknown" });
    return json(500, { error: "internal", message: "Something went wrong. Please try again." });
  }
});
