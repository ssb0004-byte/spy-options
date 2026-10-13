// Deno-only helpers shared by the `coach` and `research` Edge Functions: key lookup, the AI
// consent check and the RLS-scoped load of the user's records. Reads use the *user-scoped*
// client, so Row Level Security limits them to the caller's own rows.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { Rows } from "./lib/context.ts";

function firstKey(envName: string): string | undefined {
  const raw = Deno.env.get(envName);
  if (!raw) return undefined;
  try {
    const keys = JSON.parse(raw) as Record<string, string>;
    return keys["default"] ?? Object.values(keys)[0];
  } catch {
    return undefined;
  }
}

export function adminKey(): string | undefined {
  return firstKey("SUPABASE_SECRET_KEYS") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? undefined;
}

export function publicKey(): string | undefined {
  return firstKey("SUPABASE_PUBLISHABLE_KEYS") ?? Deno.env.get("SUPABASE_ANON_KEY") ?? undefined;
}

export function must<T>(r: { data: T | null; error: { message: string; code?: string } | null }, what: string): T {
  if (r.error) throw new Error(`${what}: ${r.error.code ?? "db_error"}`);
  return r.data as T;
}

export async function aiConsentGranted(user: SupabaseClient): Promise<boolean> {
  const r = await user.from("consent_records").select("granted, document_version, recorded_at")
    .eq("consent_type", "ai_processing").is("deleted_at", null).order("recorded_at", { ascending: false }).limit(1);
  const row = must(r, "consent")?.[0] as any;
  return !!row && row.granted === true && Number(row.document_version) >= 1;
}

export async function loadRows(user: SupabaseClient): Promise<Rows> {
  const daysAgo = (n: number) => new Date(Date.now() - n * 86_400_000).toISOString();
  const live = (q: any) => q.is("deleted_at", null);
  const [profile, prefs, goals, meas, subs, regs, admins, symptoms, pain, effects, memories] = await Promise.all([
    user.from("user_profiles").select("*").maybeSingle(),
    user.from("user_preferences").select("unit_system, coach_personality").maybeSingle(),
    live(user.from("user_goals").select("goal, is_active, priority")),
    live(user.from("health_measurements").select("kind, value, start_at, quality, source_name").gte("start_at", daysAgo(90)).order("start_at").limit(5000)),
    live(user.from("user_substances").select("id, name, category, status, formulation, indication, is_prescribed")),
    live(user.from("substance_regimens").select("user_substance_id, dose_amount, dose_unit, route, schedule, start_date, end_date")),
    user.from("actual_administrations").select("id, user_substance_id, action, supersedes_id, recorded_at").gte("recorded_at", daysAgo(14)).limit(2000),
    live(user.from("symptom_entries").select("recorded_at, wellbeing, energy, cognitive_clarity, stiffness, side_effects_note").gte("recorded_at", daysAgo(14))),
    live(user.from("pain_entries").select("recorded_at, location, severity").gte("recorded_at", daysAgo(14))),
    live(user.from("adverse_effect_reports").select("summary, severity, onset_at, user_substance_id").is("resolved_at", null)),
    user.from("coach_memory").select("category, content").eq("status", "active").order("created_at").limit(30),
  ]);
  return {
    profile: must(profile, "profile") as any, preferences: must(prefs, "prefs") as any,
    goals: must(goals, "goals") as any[], measurements: must(meas, "measurements") as any[],
    substances: must(subs, "substances") as any[], regimens: must(regs, "regimens") as any[],
    administrations: must(admins, "administrations") as any[], symptoms: must(symptoms, "symptoms") as any[],
    pain: must(pain, "pain") as any[], adverseEffects: must(effects, "effects") as any[], memories: must(memories, "memories") as any[],
  };
}
