// Request orchestration for the `research` Edge Function. Database, research-API fetch, cache
// and model are injected so the whole pipeline is unit-testable offline.
//
// insight_card / discover:  consent → red-flag triage → per-user card cache → budget →
//                           retrieval (shared cache) → deterministic checks → model → guards
//                           (citations verified, evidence capped, dosing stripped) → persist
// check_updates:            consent → retrieval → meaningful-update filter → alerts (no model call)
import { buildContext, type CoachContext, type Rows } from "../../coach/lib/context.ts";
import { checkBudget, estimateTokens, monthStart, type UsageSnapshot } from "../../coach/lib/budget.ts";
import { ProviderError, type ModelConfig, type ModelResult } from "../../coach/lib/openai.ts";
import { DOSING_REFERRAL, mergeTriage, sanitizeUserText, screenRedFlags, stripDosing, triageMessage, type TriageResult } from "../../coach/lib/safety.ts";
import { anecdotalBlock, capEvidence, levelRank, supportedLevel, verifyCitations, type AnecdotalBlock, type Citation, type EvidenceAssessment } from "./evidence.ts";
import { retrieveEvidence, retrieveLabel, sanitizeTerm, termKey, type Evidence, type FetchLike, type LabelInfo, type ResearchCache, type SourceStatus } from "./sources.ts";
import { crossCheck, type InteractionFlag, type MedContext } from "./interactions.ts";
import { buildCandidates, detectComplaints, establishedApproaches, type Candidate, type EstablishedApproach } from "./candidates.ts";
import { buildResearchRequest, evidenceList, parseCard, parseDiscover, RESEARCH_PROMPT_VERSION } from "./prompt.ts";
import { meaningfulUpdates, snapshotOf, type AlertDraft, type Snapshot } from "./updates.ts";

export type Op = "insight_card" | "discover" | "interests_list" | "interests_add" | "interests_remove" | "check_updates";
const OPS: Op[] = ["insight_card", "discover", "interests_list", "interests_add", "interests_remove", "check_updates"];

export interface ResearchRequest {
  op: Op;
  compound?: string;
  question?: string;
  concern?: string;
  term?: string;
  kind?: "compound" | "topic";
  display_name?: string;
  id?: string;
  max?: number;
  force_refresh?: boolean;
  local_date?: string;
  timezone?: string;
}

export interface Interest {
  id: string; kind: string; term: string; display_name: string | null;
  created_at?: string; last_checked_at: string | null; last_seen: Snapshot | null;
}
export interface StoredAlert { id: string; interest_id: string; kind: string; title: string; summary: string; citation: Citation; created_at?: string; seen_at?: string | null }
export interface StoredInsight { id: string; kind: string; compound_key: string; context_hash: string; payload: Record<string, unknown>; created_at?: string }

export interface ResearchDb {
  aiConsentGranted(): Promise<boolean>;
  loadRows(today: string): Promise<Rows>;
  config(): Promise<ModelConfig>;
  usage(userId: string, utcDay: string, monthStart: string, sinceIso: string): Promise<UsageSnapshot>;
  recordUsage(userId: string, utcDay: string, input: number, output: number): Promise<void>;
  findInsight(userId: string, kind: "card" | "discovery", compoundKey: string, contextHash: string, sinceIso: string): Promise<StoredInsight | null>;
  saveInsight(userId: string, row: { kind: "card" | "discovery"; compound_key: string; compound_name: string; context_hash: string; evidence_level: string | null; payload: Record<string, unknown>; model: string; prompt_version: string; last_verified_at: string }): Promise<StoredInsight>;
  listInterests(userId: string): Promise<Interest[]>;
  addInterest(userId: string, row: { kind: string; term: string; display_name: string | null }): Promise<Interest>;
  removeInterest(userId: string, id: string): Promise<boolean>;
  updateInterest(userId: string, id: string, lastSeen: Snapshot, checkedAt: string): Promise<void>;
  saveAlerts(userId: string, interestId: string, alerts: AlertDraft[]): Promise<StoredAlert[]>;
}

export interface ResearchDeps {
  db: ResearchDb;
  cache: ResearchCache;
  fetch: FetchLike;
  model: (body: Record<string, unknown>) => Promise<ModelResult>;
  now: () => Date;
  ncbiApiKey?: string;
  onFetch?: (url: string) => void;
}

export interface Reply { status: number; body: Record<string, unknown> }

export const CARD_TTL_MS = 7 * 86_400_000;
export const DISCOVERY_TTL_MS = 86_400_000;
export const UPDATE_SOURCE_TTL_MS = 86_400_000;
export const MAX_INTERESTS = 25;
const CHECK_INTERVAL_MS = 12 * 3_600_000;
const MAX_CHECKS_PER_CALL = 10;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const DISCLAIMER =
  "Educational summary of published research, not medical advice. It may be incomplete or out of date. " +
  "Talk with your clinician or pharmacist before starting, stopping or combining any compound.";

const err = (status: number, code: string, message: string): Reply => ({ status, body: { error: code, message } });
const CONSENT = () => err(403, "consent_required", "Turn on 'AI processing of health information' in Profile → Privacy → Consents to use Research.");

/** Small, stable, non-cryptographic hash (FNV-1a) for cache keys. */
export function fnv1a(s: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(16).padStart(8, "0");
}

export function medContext(rows: Rows): MedContext {
  const p = rows.profile ?? {};
  const list = (x: unknown) => (Array.isArray(x) ? x.filter((v) => typeof v === "string").slice(0, 20) as string[] : []);
  return {
    compounds: rows.substances.filter((s) => ["active", "planned", "paused"].includes(s.status)).slice(0, 30).map((s) => ({ name: String(s.name), category: String(s.category) })),
    conditions: list(p.medical_conditions),
    allergies: list(p.allergies),
  };
}

/** What the model sees about the user: goals, complaints, compound names, conditions. No doses, no raw measurements. */
function userContextFor(ctx: CoachContext, med: MedContext, complaints: string[]): Record<string, unknown> {
  return {
    goals: ctx.goals,
    complaints,
    pain_last_14_days: ctx.pain_last_14_days,
    current_compounds: med.compounds,
    medical_conditions: med.conditions,
    allergies: med.allergies,
    age: ctx.profile.age ?? null,
  };
}

const UNSAFE_CLAIM = /\b(?:is|are|it's|completely|totally|perfectly|very) safe\b|\bno (?:known )?(?:drug )?interactions?\b|\bwithout (?:any )?side[- ]effects\b|\bno side[- ]effects\b/i;

/** Removes dosing and absolute-safety claims from one text field. */
export function guardText(text: string, terms: string[], applied: Set<string>): string {
  const d = stripDosing(text, terms);
  if (d.removed) applied.add("dosing_removed");
  const parts = d.text.split(/(?<=[.!?])\s+/);
  const kept = parts.filter((p) => !UNSAFE_CLAIM.test(p));
  if (kept.length !== parts.length) applied.add("safety_claim_removed");
  return kept.join(" ").trim();
}

function regulatoryStatus(ev: Evidence) {
  const fdaSource = ev.sources.find((s) => s.source === "fda_label");
  const checked = fdaSource?.fetched_at?.slice(0, 10) ?? null;
  const wada = { status: "unknown", note: "Not checked automatically. Competitive athletes should check the current WADA Prohibited List (wada-ama.org) or Global DRO." };
  if (!fdaSource || !fdaSource.ok) {
    return { fda: "unknown", summary: "Unknown — the FDA label database could not be checked right now.", wada, sources: [] as string[], checked_at: null };
  }
  const l = ev.label;
  if (l && l.approved) {
    const ind = l.indications ? ` Labeled uses (from the label): ${l.indications.slice(0, 300)}${l.indications.length > 300 ? "…" : ""}` : "";
    return { fda: "approved_label", summary: `An FDA-approved drug label exists (${l.application_numbers.join(", ")}).${ind}`, wada, sources: [`fda_label:${l.set_id}`], checked_at: checked };
  }
  if (l) {
    return { fda: "label_without_application", summary: `An FDA drug label is listed (${l.product_type ?? "product type not stated"}) without an NDA/ANDA/BLA approval number — often an OTC monograph or unapproved marketed product. Approval status can't be confirmed from this source.`, wada, sources: [`fda_label:${l.set_id}`], checked_at: checked };
  }
  return {
    fda: "no_label_found",
    summary: `No FDA drug label was found in openFDA (checked ${checked}). This usually means it is not an FDA-approved drug — for example investigational peptides, compounded preparations and dietary supplements (which FDA does not approve) — but absence from this database is not proof.`,
    wada, sources: [] as string[], checked_at: checked,
  };
}

/** Structured-data red flags for proactive discovery (no free text). */
export function dataTriage(ctx: CoachContext): TriageResult {
  const flags: TriageResult["flags"] = [];
  const severe = ctx.pain_last_14_days.filter((p) => Number(p.highest_0_to_10) >= 8);
  if (severe.length) flags.push({ id: "severe_recent_pain", label: `pain logged at 8/10 or higher (${severe.map((p) => p.location).join(", ")}) in the last 14 days`, level: "see_clinician" });
  const sideEffects = ctx.open_side_effects.filter((e) => e.severity === "severe");
  if (sideEffects.length) flags.push({ id: "severe_side_effect", label: "an unresolved severe side effect", level: "see_clinician" });
  const level = flags.length ? "see_clinician" : "none";
  return { level, stop: false, flags, message: triageMessage(level, flags.map((f) => f.label)) };
}

function todayFor(req: ResearchRequest, now: Date): string {
  if (/^\d{4}-\d{2}-\d{2}$/.test(req.local_date ?? "")) return req.local_date!;
  return now.toISOString().slice(0, 10);
}

async function budgetOk(deps: ResearchDeps, userId: string, cfg: ModelConfig, promptChars: number): Promise<Reply | null> {
  const now = deps.now();
  const utcDay = now.toISOString().slice(0, 10);
  const usage = await deps.db.usage(userId, utcDay, monthStart(utcDay), new Date(now.getTime() - 60_000).toISOString());
  const decision = checkBudget(usage, cfg, estimateTokens(promptChars, Math.max(cfg.max_output_tokens, 2500)));
  return decision.allowed ? null : err(429, decision.code, decision.message);
}

async function callModel(deps: ResearchDeps, userId: string, body: Record<string, unknown>): Promise<{ text: string | null } | Reply> {
  let result: ModelResult;
  try {
    result = await deps.model(body);
  } catch (e) {
    const code = e instanceof ProviderError ? e.code : "error";
    const status = e instanceof ProviderError && e.status === 429 ? 503 : 502;
    return err(status, "provider_unavailable", `Research summaries are unavailable right now (${code}). Please try again shortly.`);
  }
  await deps.db.recordUsage(userId, deps.now().toISOString().slice(0, 10), result.inputTokens, result.outputTokens);
  return { text: result.text };
}

const isReply = (x: unknown): x is Reply => !!x && typeof (x as Reply).status === "number" && typeof (x as Reply).body === "object";

function retrieveDeps(deps: ResearchDeps, ttlMs?: number) {
  return { fetch: deps.fetch, cache: deps.cache, now: deps.now, ncbiApiKey: deps.ncbiApiKey, onFetch: deps.onFetch, ttlMs };
}

const LABEL_CATEGORIES = new Set(["prescription", "otc", "hormone"]);

// ---------------------------------------------------------------------------------------------

export async function handle(req: ResearchRequest, userId: string, deps: ResearchDeps): Promise<Reply> {
  if (!req || !OPS.includes(req.op)) return err(400, "bad_op", "Unknown research request.");
  switch (req.op) {
    case "interests_list": return { status: 200, body: { interests: (await deps.db.listInterests(userId)).map(publicInterest) } };
    case "interests_remove": {
      if (!UUID.test(req.id ?? "")) return err(400, "bad_id", "Unknown interest.");
      return { status: 200, body: { removed: await deps.db.removeInterest(userId, req.id!) } };
    }
    default: break;
  }
  // Everything below sends data to research APIs or the AI provider: AI consent is required.
  if (!(await deps.db.aiConsentGranted())) return CONSENT();
  switch (req.op) {
    case "interests_add": return addInterest(req, userId, deps);
    case "check_updates": return checkUpdates(req, userId, deps);
    case "insight_card": return insightCard(req, userId, deps);
    case "discover": return discover(req, userId, deps);
  }
  return err(400, "bad_op", "Unknown research request.");
}

function publicInterest(i: Interest) {
  return { id: i.id, kind: i.kind, term: i.term, display_name: i.display_name, created_at: i.created_at ?? null, last_checked_at: i.last_checked_at };
}

async function addInterest(req: ResearchRequest, userId: string, deps: ResearchDeps): Promise<Reply> {
  const term = sanitizeTerm(req.term);
  if (!term) return err(400, "bad_term", "Please enter a compound or topic name (letters and numbers only, up to 80 characters).");
  const existing = await deps.db.listInterests(userId);
  const dup = existing.find((i) => termKey(i.term) === termKey(term));
  if (dup) return { status: 200, body: { interest: publicInterest(dup), created: false } };
  if (existing.length >= MAX_INTERESTS) return err(400, "too_many_interests", `You can follow up to ${MAX_INTERESTS} topics. Remove one to add another.`);
  const kind = req.kind === "topic" ? "topic" : "compound";
  const display = typeof req.display_name === "string" ? req.display_name.trim().slice(0, 80) || null : null;
  const interest = await deps.db.addInterest(userId, { kind, term, display_name: display });
  return { status: 200, body: { interest: publicInterest(interest), created: true } };
}

async function checkUpdates(req: ResearchRequest, userId: string, deps: ResearchDeps): Promise<Reply> {
  const now = deps.now();
  const interests = (await deps.db.listInterests(userId))
    .filter((i) => req.force_refresh || !i.last_checked_at || now.getTime() - Date.parse(i.last_checked_at) >= CHECK_INTERVAL_MS)
    .sort((a, b) => (a.last_checked_at ?? "").localeCompare(b.last_checked_at ?? ""))
    .slice(0, MAX_CHECKS_PER_CALL);
  const alerts: StoredAlert[] = [];
  let checked = 0;
  for (const i of interests) {
    let ev: Evidence;
    try { ev = await retrieveEvidence(i.term, retrieveDeps(deps, UPDATE_SOURCE_TTL_MS)); } catch { continue; }
    if (!ev.sources.some((s) => s.ok)) continue;
    checked++;
    const drafts = meaningfulUpdates(i.display_name || i.term, i.last_seen, ev);
    if (drafts.length) alerts.push(...await deps.db.saveAlerts(userId, i.id, drafts));
    await deps.db.updateInterest(userId, i.id, snapshotOf(ev, i.last_seen), now.toISOString());
  }
  return { status: 200, body: { alerts, checked, checked_at: now.toISOString() } };
}

// ---------------------------------------------------------------------------------------------

export interface CompoundCard {
  name: string;
  query: string;
  category: string;
  mechanism: string;
  studied_applications: { application: string; summary: string; evidence: EvidenceAssessment; citations: Citation[] }[];
  evidence: EvidenceAssessment;
  preclinical_findings: string;
  anecdotal_reports: AnecdotalBlock;
  risks_unknowns: string[];
  regulatory_status: ReturnType<typeof regulatoryStatus>;
  contraindications_interactions: InteractionFlag[];
  interaction_considerations: string[];
  established_approaches: EstablishedApproach[];
  comparison_to_established: string;
  personalized_note: string;
  dosing_note: string;
  citations: Citation[];
  sources_checked: SourceStatus[];
  dropped_citation_ids: string[];
  guard_applied: string[];
  research_retrieved_at: string;
  last_verified_at: string;
  disclaimer: string;
}

async function insightCard(req: ResearchRequest, userId: string, deps: ResearchDeps): Promise<Reply> {
  const compound = sanitizeTerm(req.compound);
  if (!compound) return err(400, "bad_term", "Please enter a compound or intervention name.");
  const question = sanitizeUserText(req.question ?? "", 1000);
  const now = deps.now();
  const today = todayFor(req, now);

  // 1. Red-flag triage on the user's own words, before anything else.
  const triage = screenRedFlags(`${question}`);
  if (triage.stop) return { status: 200, body: { triage, card: null, stopped: true } };

  const rows = await deps.db.loadRows(today);
  const ctx = buildContext(rows, today, "UTC");
  const med = medContext(rows);
  const complaints = detectComplaints(ctx, question);

  // 2. Per-user card cache (keyed by compound + the context that personalizes it).
  const compoundKey = termKey(compound);
  const contextHash = fnv1a(JSON.stringify([question.toLowerCase(), med, complaints, ctx.goals]));
  if (!req.force_refresh) {
    const cached = await deps.db.findInsight(userId, "card", compoundKey, contextHash, new Date(now.getTime() - CARD_TTL_MS).toISOString());
    if (cached) return { status: 200, body: { card: cached.payload, triage: triage.level === "none" ? null : triage, cached: true, insight_id: cached.id } };
  }

  // 3. Budget pre-check (rough size) before spending research-API or model calls.
  const cfg = await deps.db.config();
  const over = await budgetOk(deps, userId, cfg, 12_000);
  if (over) return over;

  // 4. Retrieval: only the compound term (and the user's Rx/OTC compound names for label lookups) leave the server.
  const rdeps = retrieveDeps(deps);
  const ev = await retrieveEvidence(compound, rdeps);
  if (!ev.sources.some((s) => s.ok)) return err(503, "research_unavailable", "Research databases couldn't be reached right now. Please try again later.");
  const userLabels = new Map<string, LabelInfo | null>();
  for (const c of med.compounds.filter((c) => LABEL_CATEGORIES.has(c.category)).slice(0, 5)) {
    if (c.name.toLowerCase() !== compound.toLowerCase()) userLabels.set(c.name, await retrieveLabel(c.name, rdeps));
  }
  const flags = crossCheck(compound, ev.label, userLabels, med);
  const established = establishedApproaches(complaints);

  // 5. Model.
  const evidence = [...ev.citations].sort((a, b) => kindRank(b) - kindRank(a)).slice(0, 30);
  const data = [
    `<compound>${compound}</compound>`,
    `<question>${question || "(none)"}</question>`,
    `<user_context>${JSON.stringify(userContextFor(ctx, med, complaints))}</user_context>`,
    `<established_approaches>${JSON.stringify(established)}</established_approaches>`,
    `<interaction_flags>${JSON.stringify(flags.map((f) => ({ with: f.with, kind: f.kind, detail: f.detail })))}</interaction_flags>`,
    `<evidence retrieved_at="${ev.retrieved_at}">${JSON.stringify(evidenceList(evidence))}</evidence>`,
  ].join("\n");
  const r = await callModel(deps, userId, buildResearchRequest(cfg, "card", data));
  if (isReply(r)) return r;
  const out = r.text ? parseCard(r.text) : null;
  if (!out) return err(502, "bad_model_output", "The research summary couldn't be read. Please try again.");

  // 6. Deterministic guards.
  const applied = new Set<string>();
  const terms = [compound, out.name].filter(Boolean);
  const g = (t: string) => guardText(t, terms, applied);
  const verified = verifyCitations(out.cited_ids, evidence);
  const apps = out.studied_applications.map((a) => {
    const v = verifyCitations(a.cited_ids, evidence);
    verified.dropped.push(...v.dropped);
    for (const c of v.citations) if (!verified.citations.includes(c)) verified.citations.push(c);
    return { application: g(a.application), summary: g(a.summary), evidence: capEvidence(a.evidence_level, v.citations), citations: v.citations };
  });
  const anecdotes = g(out.anecdotal_summary);
  const overall = capEvidence(out.evidence_level, verified.citations, { hasAnecdotes: !!anecdotes, modelExplanation: g(out.evidence_explanation) });
  if (verified.dropped.length) applied.add("invented_citations_dropped");
  if (overall.capped || apps.some((a) => a.evidence.capped)) applied.add("evidence_capped");

  const card: CompoundCard = {
    name: out.name || compound,
    query: compound,
    category: out.category,
    mechanism: g(out.mechanism),
    studied_applications: apps,
    evidence: overall,
    preclinical_findings: g(out.preclinical_findings),
    anecdotal_reports: anecdotalBlock(anecdotes),
    risks_unknowns: out.risks_unknowns.map(g).filter(Boolean),
    regulatory_status: regulatoryStatus(ev),
    contraindications_interactions: flags,
    interaction_considerations: out.interaction_considerations.map(g).filter(Boolean),
    established_approaches: established,
    comparison_to_established: g(out.comparison_to_established),
    personalized_note: g(out.personalized_note),
    dosing_note: DOSING_REFERRAL,
    citations: verified.citations,
    sources_checked: ev.sources,
    dropped_citation_ids: [...new Set(verified.dropped)],
    guard_applied: [...applied],
    research_retrieved_at: ev.retrieved_at,
    last_verified_at: now.toISOString(),
    disclaimer: DISCLAIMER,
  };
  const saved = await deps.db.saveInsight(userId, {
    kind: "card", compound_key: compoundKey, compound_name: card.name, context_hash: contextHash, evidence_level: card.evidence.level,
    payload: card as unknown as Record<string, unknown>, model: cfg.chat_model, prompt_version: RESEARCH_PROMPT_VERSION, last_verified_at: card.last_verified_at,
  });
  return { status: 200, body: { card, triage: triage.level === "none" ? null : triage, cached: false, insight_id: saved.id } };
}

function kindRank(c: Citation): number {
  const order = ["meta_analysis", "systematic_review", "regulatory_label", "rct", "guideline", "clinical_trial", "trial_with_results", "observational", "case_report", "review", "animal", "in_vitro", "trial_registration", "other"];
  return order.length - order.indexOf(c.study_kind);
}

// ---------------------------------------------------------------------------------------------

export interface DiscoverySuggestion {
  candidate_id: string;
  name: string;
  category: string;
  kind: string;
  reason_tags: string[];
  why_relevant: string;
  evidence: EvidenceAssessment;
  cautions: string[];
  interaction_flags: InteractionFlag[];
  citations: Citation[];
  already_in_routine: boolean;
  summarized_by_model: boolean;
}

async function discover(req: ResearchRequest, userId: string, deps: ResearchDeps): Promise<Reply> {
  const now = deps.now();
  const today = todayFor(req, now);
  const concern = sanitizeUserText(req.concern ?? "", 1000);
  const rows = await deps.db.loadRows(today);
  const ctx = buildContext(rows, today, "UTC");
  const med = medContext(rows);

  // 1. Red-flag triage first (free-text concern + structured pain/side-effect data).
  const triage = mergeTriage(screenRedFlags(concern), dataTriage(ctx));
  if (triage.stop) return { status: 200, body: { triage, suggestions: [], stopped: true } };

  const interests = await deps.db.listInterests(userId);
  const max = Math.min(Math.max(Number(req.max) || 6, 1), 8);
  const candidates = buildCandidates(ctx, interests, max, concern);
  if (!candidates.length) {
    return { status: 200, body: { triage: triage.level === "none" ? null : triage, suggestions: [], additional_topics: [], summary: "Add goals, log pain or follow a research topic to get personalized suggestions.", generated_at: now.toISOString() } };
  }

  const contextHash = fnv1a(JSON.stringify([concern.toLowerCase(), candidates.map((c) => c.id), med, today]));
  if (!req.force_refresh) {
    const cached = await deps.db.findInsight(userId, "discovery", "discover", contextHash, new Date(now.getTime() - DISCOVERY_TTL_MS).toISOString());
    if (cached) return { status: 200, body: { ...cached.payload, triage: triage.level === "none" ? null : triage, cached: true } };
  }

  const cfg = await deps.db.config();
  const over = await budgetOk(deps, userId, cfg, 15_000);
  if (over) return over;

  const rdeps = retrieveDeps(deps);
  const evByCandidate = new Map<string, Evidence>();
  for (const c of candidates) {
    try {
      const ev = await retrieveEvidence(c.search_term, rdeps, { label: c.kind !== "non_drug", trials: true });
      if (ev.sources.some((s) => s.ok)) evByCandidate.set(c.id, ev);
    } catch { /* skip candidate */ }
  }
  if (!evByCandidate.size) return err(503, "research_unavailable", "Research databases couldn't be reached right now. Please try again later.");
  const usable = candidates.filter((c) => evByCandidate.has(c.id));
  const topCitations = (c: Candidate) => [...evByCandidate.get(c.id)!.citations].sort((a, b) => kindRank(b) - kindRank(a)).slice(0, 10);

  const complaints = detectComplaints(ctx, concern);
  const data = [
    `<user_context>${JSON.stringify(userContextFor(ctx, med, complaints))}</user_context>`,
    `<concern>${concern || "(none)"}</concern>`,
    `<candidates>${JSON.stringify(usable.map((c) => ({ candidate_id: c.id, name: c.name, kind: c.kind, why_listed: c.reason_tags, evidence: evidenceList(topCitations(c)) })))}</candidates>`,
  ].join("\n");
  const r = await callModel(deps, userId, buildResearchRequest(cfg, "discover", data));
  if (isReply(r)) return r;
  const out = r.text ? parseDiscover(r.text) : null;
  if (!out) return err(502, "bad_model_output", "The research summary couldn't be read. Please try again.");

  const applied = new Set<string>();
  const routine = new Set(med.compounds.map((c) => c.name.toLowerCase()));
  const suggestions: DiscoverySuggestion[] = [];
  for (const s of out.suggestions) {
    const c = usable.find((x) => x.id === s.candidate_id);
    if (!c || suggestions.some((x) => x.candidate_id === c.id)) continue;
    const ev = evByCandidate.get(c.id)!;
    const v = verifyCitations(s.cited_ids, topCitations(c));
    if (v.dropped.length) applied.add("invented_citations_dropped");
    const terms = c.kind === "non_drug" ? [] : [c.name, c.search_term];
    const g = (t: string) => guardText(t, terms, applied);
    const evidence = capEvidence(s.evidence_level, v.citations, { modelExplanation: g(s.evidence_explanation) });
    if (evidence.capped) applied.add("evidence_capped");
    suggestions.push({
      candidate_id: c.id, name: c.name, category: c.category, kind: c.kind, reason_tags: c.reason_tags,
      why_relevant: g(s.why_relevant), evidence, cautions: s.cautions.map(g).filter(Boolean),
      interaction_flags: c.kind === "non_drug" ? [] : crossCheck(c.name, ev.label, new Map(), med).filter((f) => f.kind !== "no_data"),
      citations: v.citations, already_in_routine: routine.has(c.name.toLowerCase()) || routine.has(c.search_term.toLowerCase()),
      summarized_by_model: true,
    });
  }
  // Non-drug options are always represented, even if the model skipped them.
  if (!suggestions.some((s) => s.kind === "non_drug")) {
    for (const c of usable.filter((x) => x.kind === "non_drug").slice(0, 2)) {
      const cites = topCitations(c).slice(0, 5);
      const sup = supportedLevel(cites);
      suggestions.push({
        candidate_id: c.id, name: c.name, category: c.category, kind: c.kind, reason_tags: c.reason_tags,
        why_relevant: `Listed because of ${c.reason_tags.join(", ")}.`,
        evidence: capEvidence(sup.level, cites, { modelExplanation: "Not summarized; level derived automatically from the designs of the retrieved studies." }),
        cautions: [], interaction_flags: [], citations: cites, already_in_routine: false, summarized_by_model: false,
      });
      applied.add("non_drug_added");
    }
  }
  suggestions.sort((a, b) => levelRank(b.evidence.level) - levelRank(a.evidence.level));
  const additional = out.additional_topics
    .map((t) => ({ name: t.name, search_term: sanitizeTerm(t.search_term), category: t.category, why: guardText(t.why, [], applied) }))
    .filter((t) => t.search_term);

  const payload = {
    summary: guardText(out.summary, [], applied),
    suggestions,
    additional_topics: additional,
    guard_applied: [...applied],
    dosing_note: DOSING_REFERRAL,
    disclaimer: DISCLAIMER,
    generated_at: now.toISOString(),
  };
  await deps.db.saveInsight(userId, {
    kind: "discovery", compound_key: "discover", compound_name: "Discovery", context_hash: contextHash, evidence_level: null,
    payload, model: cfg.chat_model, prompt_version: RESEARCH_PROMPT_VERSION, last_verified_at: now.toISOString(),
  });
  return { status: 200, body: { ...payload, triage: triage.level === "none" ? null : triage, cached: false } };
}
