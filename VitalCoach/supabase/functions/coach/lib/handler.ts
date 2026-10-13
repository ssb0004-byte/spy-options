// Request orchestration for the coach. Database and model access are injected so the whole
// flow (consent, budgets, safety short-circuits, caching, persistence) is unit-testable.
import { buildContext, type CoachContext, type Rows } from "./context.ts";
import { checkBudget, estimateTokens, monthStart, weekStart, type UsageSnapshot } from "./budget.ts";
import { buildRequest, ProviderError, type ChatTurn, type ModelConfig, type ModelResult } from "./openai.ts";
import { dataBlock, instructions, parseOutput, type Mode } from "./prompt.ts";
import { guardReply, sanitizeUserText, screenRedFlags, screenUrgent, URGENT_MESSAGE } from "./safety.ts";

export type RequestMode = Mode | "context_preview";

export interface CoachRequest {
  mode: RequestMode;
  message?: string;
  conversation_id?: string;
  timezone?: string;
  local_date?: string;
  force_refresh?: boolean;
}

export interface Insight { id: string; kind: string; for_date: string; title: string; body: string; payload: Record<string, unknown>; status: string; created_at?: string }
export interface StoredMessage { id: string; conversation_id: string; role: string; content: string; metadata: Record<string, unknown>; created_at?: string }

export interface Db {
  aiConsentGranted(): Promise<boolean>;
  loadRows(today: string): Promise<Rows>;
  config(): Promise<ModelConfig>;
  usage(userId: string, utcDay: string, monthStart: string, sinceIso: string): Promise<UsageSnapshot>;
  recordUsage(userId: string, utcDay: string, input: number, output: number): Promise<void>;
  findInsight(userId: string, kind: string, forDate: string): Promise<Insight | null>;
  saveInsight(userId: string, i: Omit<Insight, "id" | "status">, model: string, promptVersion: string): Promise<Insight>;
  conversation(userId: string, id: string | undefined, kind: string, title: string): Promise<string>;
  history(conversationId: string, limit: number): Promise<ChatTurn[]>;
  saveMessage(userId: string, m: Omit<StoredMessage, "id">, extra?: { model?: string; prompt_version?: string; input_tokens?: number; output_tokens?: number }): Promise<StoredMessage>;
  proposeMemories(userId: string, messageId: string, memories: { category: string; content: string }[]): Promise<number>;
}

export interface Deps {
  db: Db;
  model: (body: Record<string, unknown>) => Promise<ModelResult>;
  now: () => Date;
}

export interface Reply { status: number; body: Record<string, unknown> }

const MAX_MESSAGE_CHARS = 4000;
const HISTORY_TURNS = 12;
const MODES: RequestMode[] = ["chat", "morning_briefing", "weekly_summary", "goal_reassessment", "checkin_followup", "context_preview"];

function err(status: number, code: string, message: string): Reply {
  return { status, body: { error: code, message } };
}

export function validTimeZone(tz: string | undefined): string {
  if (!tz) return "UTC";
  try { new Intl.DateTimeFormat("en-US", { timeZone: tz }); return tz; } catch { return "UTC"; }
}

export async function handle(req: CoachRequest, userId: string, deps: Deps): Promise<Reply> {
  if (!MODES.includes(req.mode)) return err(400, "bad_mode", "Unknown request type.");
  const tz = validTimeZone(req.timezone);
  const now = deps.now();
  const today = /^\d{4}-\d{2}-\d{2}$/.test(req.local_date ?? "")
    ? req.local_date!
    : new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
  const utcDay = now.toISOString().slice(0, 10);

  const rows = await deps.db.loadRows(today);
  const ctx: CoachContext = buildContext(rows, today, tz);

  // Transparency: show the user exactly what the coach would see. Nothing is sent to the AI
  // provider, so this works before AI consent is given (it helps the user decide).
  if (req.mode === "context_preview") return { status: 200, body: { context: ctx } };

  // 1. Consent is enforced on the server, from the user's own consent ledger, before any AI call.
  if (!(await deps.db.aiConsentGranted())) {
    return err(403, "consent_required", "Turn on 'AI processing of health information' in Profile → Privacy → Consents to use the coach.");
  }

  const message = req.mode === "chat" || req.mode === "checkin_followup" ? sanitizeUserText(req.message ?? "", MAX_MESSAGE_CHARS) : "";
  if (req.mode === "chat" && !message) return err(400, "empty_message", "Please type a message.");

  // 2. Cached once-per-period insights cost nothing to re-open.
  const periodKind = req.mode === "morning_briefing" || req.mode === "weekly_summary" ? req.mode : null;
  const periodDate = req.mode === "weekly_summary" ? weekStart(today) : today;
  if (periodKind && !req.force_refresh) {
    const cached = await deps.db.findInsight(userId, periodKind, periodDate);
    if (cached) return { status: 200, body: { insight: cached, cached: true } };
  }

  // 3. Deterministic emergency screen and red-flag triage before any model call.
  const triage = message ? screenRedFlags(message) : null;
  const urgentPhrase = message ? screenUrgent(message).urgent : false;
  if (message && triage && (urgentPhrase || triage.stop)) {
    const emergency = urgentPhrase || triage.level === "emergency";
    const convId = await deps.db.conversation(userId, req.conversation_id, "chat", message.slice(0, 60));
    await deps.db.saveMessage(userId, { conversation_id: convId, role: "user", content: message, metadata: {} });
    // Emergency phrases keep the established wording; other red flags get the triage advice.
    const notice = await deps.db.saveMessage(userId, {
      conversation_id: convId, role: "system_notice", content: urgentPhrase ? URGENT_MESSAGE : triage.message,
      metadata: { safety: { urgent: emergency, red_flags: triage.flags.map((f) => f.id) }, source: "deterministic_screen" },
    });
    return { status: 200, body: { conversation_id: convId, message: notice, urgent: emergency, triage } };
  }

  // 4. Budgets.
  const cfg = await deps.db.config();
  const since = new Date(now.getTime() - 60_000).toISOString();
  const usage = await deps.db.usage(userId, utcDay, monthStart(utcDay), since);
  const instr = instructions(req.mode as Mode, ctx.coach_style);
  const data = dataBlock(ctx);

  let convId: string | undefined;
  let history: ChatTurn[] = [];
  if (req.mode === "chat" || req.mode === "checkin_followup") {
    convId = await deps.db.conversation(userId, req.conversation_id, req.mode, message.slice(0, 60) || "Check-in follow-up");
    history = (await deps.db.history(convId, HISTORY_TURNS)).map((t) => ({ role: t.role, content: t.content.slice(0, 2000) }));
  }
  const promptChars = instr.length + data.length + message.length + history.reduce((n, t) => n + t.content.length, 0);
  const decision = checkBudget(usage, cfg, estimateTokens(promptChars, cfg.max_output_tokens));
  if (!decision.allowed) return err(429, decision.code, decision.message);

  if (convId && message) await deps.db.saveMessage(userId, { conversation_id: convId, role: "user", content: message, metadata: {} });

  // 5. Model call with structured output.
  let result: ModelResult;
  try {
    result = await deps.model(buildRequest(cfg, instr, data, history, message || null));
  } catch (e) {
    const code = e instanceof ProviderError ? e.code : "error";
    const status = e instanceof ProviderError && e.status === 429 ? 503 : 502;
    return err(status, "provider_unavailable", `The coach couldn't respond right now (${code}). Please try again shortly.`);
  }
  await deps.db.recordUsage(userId, utcDay, result.inputTokens, result.outputTokens);

  const out = result.text ? parseOutput(result.text) : null;
  if (!out) return err(502, "bad_model_output", "The coach's reply couldn't be read. Please try again.");

  // 6. Deterministic output guard.
  const guarded = guardReply(out.reply, out.safety);
  if (triage && triage.level === "see_clinician") {
    guarded.text = `${triage.message}\n\n${guarded.text}`;
    guarded.guardApplied.push("red_flag_notice");
  }
  const metadata = {
    basis: out.basis, data_points_used: out.data_points_used, follow_up_question: out.follow_up_question,
    safety: out.safety, guard_applied: guarded.guardApplied, research_topics: out.research_topics,
  };
  const extra = { model: cfg.chat_model, prompt_version: cfg.prompt_version, input_tokens: result.inputTokens, output_tokens: result.outputTokens };

  if (convId) {
    const saved = await deps.db.saveMessage(userId, { conversation_id: convId, role: "assistant", content: guarded.text, metadata }, extra);
    const proposed = out.suggested_memories.length ? await deps.db.proposeMemories(userId, saved.id, out.suggested_memories) : 0;
    let goalProposal: Insight | null = null;
    if (out.goal_proposal) {
      goalProposal = await deps.db.saveInsight(userId, {
        kind: "goal_proposal", for_date: today, title: "Suggested goal change", body: out.goal_proposal.rationale, payload: out.goal_proposal,
      }, cfg.chat_model, cfg.prompt_version);
    }
    return { status: 200, body: { conversation_id: convId, message: saved, proposed_memories: proposed, goal_proposal: goalProposal } };
  }

  const kind = req.mode === "goal_reassessment" ? "goal_reassessment" : req.mode;
  const insight = await deps.db.saveInsight(userId, {
    kind, for_date: periodDate,
    title: out.title || (kind === "morning_briefing" ? "Today" : kind === "weekly_summary" ? "Your week" : "Goal check-in"),
    body: guarded.text,
    payload: { ...metadata, goal_proposal: out.goal_proposal },
  }, cfg.chat_model, cfg.prompt_version);
  let goalProposal: Insight | null = null;
  if (out.goal_proposal) {
    goalProposal = await deps.db.saveInsight(userId, {
      kind: "goal_proposal", for_date: today, title: "Suggested goal change", body: out.goal_proposal.rationale, payload: out.goal_proposal,
    }, cfg.chat_model, cfg.prompt_version);
  }
  return { status: 200, body: { insight, goal_proposal: goalProposal, cached: false } };
}
