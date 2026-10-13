// Run: node --experimental-strip-types --test supabase/functions/coach/lib/coach.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildContext, displayValue, ageOn, summarizeMetric, type Rows } from "./context.ts";
import { checkBudget, weekStart, monthStart, estimateTokens } from "./budget.ts";
import { guardReply, screenUrgent, hasDoseDirective, CLINICIAN_NOTICE } from "./safety.ts";
import { instructions, parseOutput, OUTPUT_SCHEMA } from "./prompt.ts";
import { buildRequest, extractResult, type ModelConfig } from "./openai.ts";
import { handle, type Db, type Insight, type StoredMessage } from "./handler.ts";

const emptyRows = (): Rows => ({ profile: null, preferences: null, goals: [], measurements: [], substances: [], regimens: [],
  administrations: [], symptoms: [], pain: [], adverseEffects: [], memories: [] });

const cfg: ModelConfig = { prompt_version: "test-1", chat_model: "test-model", reasoning_effort: "low", max_output_tokens: 1000,
  daily_token_limit_per_user: 50_000, daily_request_limit_per_user: 20, monthly_token_limit_global: 1_000_000 };

// ---------- safety ----------
test("urgent screen matches emergencies and not ordinary text", () => {
  assert.equal(screenUrgent("I have sudden CHEST PAIN").urgent, true);
  assert.equal(screenUrgent("I can’t breathe properly").urgent, true); // curly apostrophe
  assert.equal(screenUrgent("my chest workout went well").urgent, false);
});

test("dose directives get a clinician notice; study descriptions do not", () => {
  assert.equal(hasDoseDirective("You should increase to 200 mg weekly."), true);
  assert.equal(hasDoseDirective("Try 5 mg before bed."), true);
  assert.equal(hasDoseDirective("Inject 0.5 mL twice a week"), true);
  assert.equal(hasDoseDirective("Studies in adults used 3–5 g of creatine per day."), false);
  const g = guardReply("I recommend 10 mg daily.", { urgent: false, needs_clinician: false, topics: [] });
  assert.ok(g.text.endsWith(CLINICIAN_NOTICE));
  assert.deepEqual(g.guardApplied, ["dose_directive_notice"]);
  const clean = guardReply("Walk 20 minutes today.", { urgent: false, needs_clinician: false, topics: [] });
  assert.deepEqual(clean.guardApplied, []);
  const urgent = guardReply("Please rest.", { urgent: true, needs_clinician: false, topics: [] });
  assert.ok(urgent.text.includes("emergency"));
});

// ---------- context ----------
test("context includes only real data, with units and estimates labelled", () => {
  const rows = emptyRows();
  rows.preferences = { unit_system: "imperial", coach_personality: "direct_accountability" };
  rows.profile = { date_of_birth: "1985-10-20", height_cm: 180, physiological_sex: "prefer_not_to_say", allergies: ["penicillin"] };
  rows.goals = [{ goal: "fat_loss", is_active: true }, { goal: "strength", is_active: false }];
  const day = (d: number) => `2026-10-${String(d).padStart(2, "0")}T12:00:00Z`;
  for (let d = 1; d <= 13; d++) rows.measurements.push({ kind: "body_mass", value: 90 - d * 0.1, start_at: day(d), quality: "measured", source_name: "Arboleaf" });
  rows.measurements.push({ kind: "body_fat_percentage", value: 22.5, start_at: day(13), quality: "estimated", source_name: "Arboleaf" });
  const ctx = buildContext(rows, "2026-10-13", "UTC");
  assert.equal(ctx.units, "imperial");
  assert.equal(ctx.profile.age, 40);
  assert.equal(ctx.profile.physiological_sex, undefined); // "prefer not to say" is not sent
  assert.equal(ctx.profile.height, "70.9 in");
  assert.deepEqual(ctx.goals, ["fat_loss"]);
  const weight = ctx.measurements.find((m) => m.metric === "Weight")!;
  assert.match(String(weight.latest), /lb$/);
  assert.equal(weight.latest_date, "2026-10-13");
  assert.equal(weight.trend, "not enough data to compare periods"); // only 13 days: no 3–5-week-ago window
  const fat = ctx.measurements.find((m) => String(m.metric).startsWith("Body fat"))!;
  assert.equal(fat.quality, "estimated");
  assert.equal(ctx.coach_style, "direct_accountability");
  assert.ok(ctx.notes.some((n) => n.includes("Anything not listed is unknown")));
});

test("period comparison appears only with data in both windows", () => {
  const rows: Record<string, any>[] = [];
  for (let d = 0; d < 40; d++) {
    const date = new Date(Date.UTC(2026, 8, 4 + d)).toISOString();
    rows.push({ kind: "body_mass", value: 100 - d * 0.1, start_at: date, quality: "measured" });
  }
  const s = summarizeMetric(rows, "body_mass", "2026-10-13", "UTC", "metric")!;
  assert.ok(s.change, "has change");
  assert.match(String(s.change), /^-\d/);
});

test("dose log uses effective records only and never infers 'taken'", () => {
  const rows = emptyRows();
  rows.substances = [{ id: "s1", name: "Magnesium", category: "vitamin_mineral", status: "active" }];
  rows.regimens = [{ user_substance_id: "s1", dose_amount: "400.000000", dose_unit: "mg", route: "oral", schedule: { frequency: "daily", times: [{ hour: 21, minute: 0 }] }, start_date: "2026-09-01", end_date: null }];
  rows.administrations = [
    { id: "a1", user_substance_id: "s1", action: "taken" },
    { id: "a2", user_substance_id: "s1", action: "skipped", supersedes_id: "a1" }, // correction
    { id: "a3", user_substance_id: "s1", action: "taken" },
    { id: "a4", user_substance_id: "s1", action: "voided", supersedes_id: "a3" },  // undo
  ];
  const ctx = buildContext(rows, "2026-10-13", "UTC");
  assert.deepEqual(ctx.dose_log_last_14_days, [{ name: "Magnesium", taken: 0, skipped: 1, missed: 0 }]);
  assert.equal(ctx.routine[0].current_dose, "400 mg, oral");
  assert.equal(ctx.routine[0].schedule, "daily at 21:00");
});

test("units and age helpers", () => {
  assert.deepEqual(displayValue("body_mass", 90.718474, "imperial"), { value: 200, unit: "lb" });
  assert.deepEqual(displayValue("waist_circumference", 86.36, "imperial"), { value: 34, unit: "in" });
  assert.equal(ageOn("2008-10-14", "2026-10-13"), 17);
  assert.equal(ageOn(null, "2026-10-13"), null);
});

// ---------- budget ----------
test("budget limits", () => {
  const ok = { userTokensToday: 0, userRequestsToday: 0, userRequestsLastMinute: 0, globalTokensThisMonth: 0 };
  assert.equal(checkBudget(ok, cfg, 1000).allowed, true);
  assert.deepEqual((checkBudget({ ...ok, userRequestsLastMinute: 6 }, cfg, 10) as any).code, "rate_limited");
  assert.deepEqual((checkBudget({ ...ok, userTokensToday: 49_500 }, cfg, 1000) as any).code, "daily_limit");
  assert.deepEqual((checkBudget({ ...ok, userRequestsToday: 20 }, cfg, 1) as any).code, "daily_limit");
  assert.deepEqual((checkBudget({ ...ok, globalTokensThisMonth: 999_999 }, cfg, 10) as any).code, "service_budget");
  assert.equal(weekStart("2026-10-13"), "2026-10-12"); // Tuesday → Monday
  assert.equal(weekStart("2026-10-12"), "2026-10-12");
  assert.equal(weekStart("2026-10-18"), "2026-10-12"); // Sunday → previous Monday
  assert.equal(monthStart("2026-10-13"), "2026-10-01");
  assert.equal(estimateTokens(4000, 500), 1500);
});

// ---------- prompt / schema / parsing ----------
test("instructions carry style and non-negotiable boundaries", () => {
  const i = instructions("chat", "clinical_analytical");
  assert.match(i, /clinician-scientist/);
  assert.match(i, /Never tell the user to start, stop, taper, or change the dose/);
  assert.match(i, /never invent studies/);
  assert.match(i, /do not prove cause and effect/);
  assert.match(instructions("chat", "unknown_style"), /balance of encouraging/);
});

test("schema is strict-mode compatible (every property required, no extras)", () => {
  const check = (s: any) => {
    if (s.anyOf) return s.anyOf.forEach(check);
    if (s.type === "object") {
      assert.equal(s.additionalProperties, false);
      assert.deepEqual([...s.required].sort(), Object.keys(s.properties).sort());
      Object.values(s.properties).forEach(check);
    }
    if (s.type === "array") check(s.items);
  };
  check(OUTPUT_SCHEMA);
});

test("parseOutput validates and clamps model output", () => {
  assert.equal(parseOutput("not json"), null);
  assert.equal(parseOutput(JSON.stringify({ reply: "" })), null);
  const o = parseOutput(JSON.stringify({
    title: "T", reply: "Hi", basis: "weird", data_points_used: ["a", 5], follow_up_question: "  ",
    suggested_memories: [{ category: "preference", content: "Short answers" }, { category: "diagnosis", content: "x" }, { category: "other", content: "b" }, { category: "other", content: "c" }],
    goal_proposal: { add: ["fat_loss", "fly"], remove: [], rationale: "r" },
    safety: { urgent: "yes", needs_clinician: true, topics: ["peptide", "bogus"] },
  }))!;
  assert.equal(o.basis, "general_education");
  assert.deepEqual(o.data_points_used, ["a"]);
  assert.equal(o.follow_up_question, null);
  assert.equal(o.suggested_memories.length, 2);
  assert.deepEqual(o.goal_proposal?.add, ["fat_loss"]);
  assert.equal(o.safety.urgent, false);
  assert.deepEqual(o.safety.topics, ["peptide"]);
});

test("request body uses Responses API with strict JSON schema and store:false", () => {
  const b: any = buildRequest(cfg, "INSTR", "<user_data>{}</user_data>", [{ role: "user", content: "earlier" }], "now");
  assert.equal(b.model, "test-model");
  assert.equal(b.store, false);
  assert.equal(b.text.format.type, "json_schema");
  assert.equal(b.text.format.strict, true);
  assert.deepEqual(b.reasoning, { effort: "low" });
  assert.equal(b.input[0].role, "developer");
  assert.equal(b.input.at(-1).content, "now");
  assert.equal(buildRequest({ ...cfg, reasoning_effort: null }, "i", "d", [], null).reasoning, undefined);
});

test("extractResult reads output_text and usage", () => {
  const r = extractResult({ status: "completed", usage: { input_tokens: 12, output_tokens: 34 },
    output: [{ type: "reasoning" }, { type: "message", content: [{ type: "output_text", text: '{"a":1}' }] }] });
  assert.equal(r.text, '{"a":1}');
  assert.equal(r.inputTokens, 12);
  assert.equal(extractResult({ output: [{ type: "message", content: [{ type: "refusal", refusal: "no" }] }] }).text, null);
});

// ---------- handler (end-to-end with fakes) ----------
function fakeDb(opts: { consent?: boolean; usage?: Partial<{ userTokensToday: number; userRequestsToday: number; userRequestsLastMinute: number; globalTokensThisMonth: number }> } = {}) {
  const state = { messages: [] as StoredMessage[], insights: [] as Insight[], memories: [] as any[], usage: [] as any[], conversations: 0 };
  const db: Db = {
    aiConsentGranted: async () => opts.consent ?? true,
    loadRows: async () => emptyRows(),
    config: async () => cfg,
    usage: async () => ({ userTokensToday: 0, userRequestsToday: 0, userRequestsLastMinute: 0, globalTokensThisMonth: 0, ...(opts.usage ?? {}) }),
    recordUsage: async (u, d, i, o) => { state.usage.push({ u, d, i, o }); },
    findInsight: async (_u, kind, date) => state.insights.find((x) => x.kind === kind && x.for_date === date) ?? null,
    saveInsight: async (_u, i) => { const x = { ...i, id: `i${state.insights.length}`, status: "new" }; state.insights.push(x); return x; },
    conversation: async (_u, id) => id ?? `c${++state.conversations}`,
    history: async (cid) => state.messages.filter((m) => m.conversation_id === cid && m.role !== "system_notice").map((m) => ({ role: m.role as any, content: m.content })),
    saveMessage: async (_u, m) => { const x = { ...m, id: `m${state.messages.length}` }; state.messages.push(x); return x; },
    proposeMemories: async (_u, mid, ms) => { state.memories.push(...ms.map((m) => ({ ...m, mid, status: "proposed" }))); return ms.length; },
  };
  return { db, state };
}

const modelReturning = (o: Record<string, unknown>) => {
  const calls: any[] = [];
  const fn = async (body: Record<string, unknown>) => {
    calls.push(body);
    return { text: JSON.stringify({ title: "", basis: "general_education", data_points_used: [], follow_up_question: null, suggested_memories: [], goal_proposal: null, safety: { urgent: false, needs_clinician: false, topics: [] }, ...o }), inputTokens: 100, outputTokens: 50, status: "completed" };
  };
  return { fn, calls };
};

const now = () => new Date("2026-10-13T12:00:00Z");

test("handler refuses without AI consent and never calls the model", async () => {
  const { db } = fakeDb({ consent: false });
  const m = modelReturning({ reply: "x" });
  const r = await handle({ mode: "chat", message: "hi" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 403);
  assert.equal(r.body.error, "consent_required");
  assert.equal(m.calls.length, 0);
});

test("handler short-circuits emergencies without calling the model", async () => {
  const { db, state } = fakeDb();
  const m = modelReturning({ reply: "x" });
  const r = await handle({ mode: "chat", message: "I have chest pain and can't breathe" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 200);
  assert.equal(r.body.urgent, true);
  assert.equal(m.calls.length, 0);
  assert.equal(state.messages.at(-1)!.role, "system_notice");
});

test("handler enforces budgets before calling the model", async () => {
  const { db } = fakeDb({ usage: { userTokensToday: 49_999 } });
  const m = modelReturning({ reply: "x" });
  const r = await handle({ mode: "chat", message: "hi" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 429);
  assert.equal(r.body.error, "daily_limit");
  assert.equal(m.calls.length, 0);
});

test("chat stores messages, guards dose advice, proposes memories and records usage", async () => {
  const { db, state } = fakeDb();
  const m = modelReturning({ reply: "You should increase to 200 mg.", suggested_memories: [{ category: "preference", content: "Likes data" }] });
  const r = await handle({ mode: "chat", message: "Should I change my dose?" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 200);
  const saved = r.body.message as StoredMessage;
  assert.ok(saved.content.includes(CLINICIAN_NOTICE));
  assert.deepEqual((saved.metadata as any).guard_applied, ["dose_directive_notice"]);
  assert.equal(state.memories.length, 1);
  assert.equal(state.memories[0].status, "proposed");
  assert.equal(state.usage.length, 1);
  assert.deepEqual(state.messages.map((x) => x.role), ["user", "assistant"]);
  // Follow-up includes prior turns as history.
  await handle({ mode: "chat", message: "thanks", conversation_id: r.body.conversation_id as string }, "u1", { db, model: m.fn, now });
  assert.equal(m.calls[1].input.length, 1 + 2 + 1); // data + 2 history turns + new message
});

test("morning briefing is generated once per day, then served from cache", async () => {
  const { db } = fakeDb();
  const m = modelReturning({ reply: "Good morning", title: "Steady week" });
  const a = await handle({ mode: "morning_briefing", local_date: "2026-10-13" }, "u1", { db, model: m.fn, now });
  const b = await handle({ mode: "morning_briefing", local_date: "2026-10-13" }, "u1", { db, model: m.fn, now });
  assert.equal(a.body.cached, false);
  assert.equal(b.body.cached, true);
  assert.equal(m.calls.length, 1);
  assert.equal((a.body.insight as Insight).title, "Steady week");
});

test("goal reassessment saves a proposal for user approval", async () => {
  const { db, state } = fakeDb();
  const m = modelReturning({ reply: "Consider adding mobility.", title: "Goals", goal_proposal: { add: ["mobility"], remove: [], rationale: "Stiffness scores are high." } });
  const r = await handle({ mode: "goal_reassessment" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 200);
  assert.equal(state.insights.filter((i) => i.kind === "goal_proposal").length, 1);
  assert.equal((r.body.goal_proposal as Insight).payload.add instanceof Array, true);
});

test("context preview never calls the model and works before AI consent", async () => {
  const { db } = fakeDb({ consent: false });
  const m = modelReturning({ reply: "x" });
  const r = await handle({ mode: "context_preview" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 200);
  assert.ok(r.body.context);
  assert.equal(m.calls.length, 0);
});

test("unreadable model output is rejected, not shown", async () => {
  const { db } = fakeDb();
  const r = await handle({ mode: "chat", message: "hi" }, "u1", { db, model: async () => ({ text: "garbage", inputTokens: 1, outputTokens: 1, status: "completed" }), now });
  assert.equal(r.status, 502);
});

// ---------- Phase 3: red-flag triage and stricter dosing guard ----------
test("chat red flags (e.g. can't bear weight) return triage advice without calling the model", async () => {
  const { db, state } = fakeDb();
  const m = modelReturning({ reply: "x" });
  const r = await handle({ mode: "chat", message: "My knee gave way and now I can't put weight on it. Is BPC-157 worth trying?" }, "u1", { db, model: m.fn, now });
  assert.equal(r.status, 200);
  assert.equal(r.body.urgent, false);
  assert.equal((r.body.triage as any).level, "urgent");
  assert.equal(m.calls.length, 0);
  assert.equal(state.messages.at(-1)!.role, "system_notice");
  assert.match(state.messages.at(-1)!.content, /assessed today/);
});

test("peptide replies have dosing protocols removed, not just annotated; research topics are parsed", async () => {
  const g = guardReply("BPC-157 is investigational. People inject 250 mcg twice daily for 4 weeks. Talk to your doctor.", { urgent: false, needs_clinician: false, topics: ["peptide"] });
  assert.doesNotMatch(g.text, /250 mcg/);
  assert.match(g.text, /investigational/);
  assert.ok(g.guardApplied.includes("dose_protocol_removed"));
  assert.ok(g.text.endsWith(CLINICIAN_NOTICE));
  const o = parseOutput(JSON.stringify({ reply: "Hi", research_topics: ["BPC-157", "", 3] }))!;
  assert.deepEqual(o.research_topics, ["BPC-157"]);
});
