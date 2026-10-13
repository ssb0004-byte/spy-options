// Offline demo of the research pipeline for a FICTIONAL user.
// Run: node --experimental-strip-types --no-warnings VitalCoach/supabase/functions/research/demo/demo.ts
// Research APIs are served from fixtures (fictional studies, "[FIXTURE]"), and the AI model is a
// stub that deliberately returns problems the server must fix (an invented PMID, an inflated
// evidence level, a dosing protocol, a "completely safe" claim).
import { handle, type ResearchDeps } from "../lib/handler.ts";
import { ALEX_ID, BPC157_MODEL_OUTPUT, DISCOVER_MODEL_OUTPUT, fakeResearchDb, fixtureFetch, memoryCache, stubModel } from "./fixtures.ts";

const NOW = new Date("2026-10-14T12:00:00Z");
const { db } = fakeResearchDb();
const fetch = fixtureFetch();
const deps: ResearchDeps = { db, cache: memoryCache(), fetch, model: stubModel(BPC157_MODEL_OUTPUT).fn, now: () => NOW };

const line = (s = "") => console.log(s);
const h = (s: string) => { line(); line("=".repeat(78)); line(s); line("=".repeat(78)); };
const wrap = (s: string, indent = "  ") => {
  const words = s.split(/\s+/); let cur = indent; const out: string[] = [];
  for (const w of words) { if ((cur + w).length > 96) { out.push(cur.trimEnd()); cur = indent; } cur += w + " "; }
  out.push(cur.trimEnd()); return out.join("\n");
};

h("VitalCoach research demo — FICTIONAL user and FIXTURE data (not real studies)");
line("User: Alex Rivera (fictional), 42. Right-knee pain after running (logged 4–5/10).");
line("Goals: reduce knee pain, improve body composition. Takes: lisinopril (Rx), vitamin D3.");
line("Condition: hypertension. Research interest: BPC-157.");
line(`Run time (fixed): ${NOW.toISOString()}`);

// 1. Red-flag triage
h("1) Triage first: \"I twisted my knee, heard a pop, now I can't bear weight. Should I try BPC-157?\"");
const t = await handle({ op: "insight_card", compound: "BPC-157", question: "I twisted my knee on a run, heard a pop and now I can't bear weight. Should I try BPC-157?" }, ALEX_ID, deps);
const triage = t.body.triage as any;
line(`stopped: ${t.body.stopped}   level: ${triage.level}   flags: ${triage.flags.map((f: any) => f.id).join(", ")}`);
line(wrap(triage.message));
line(`Research API calls made: ${fetch.urls.length}   (compound discussion stopped before any lookup or AI call)`);

// 2. Insight card
h("2) Compound Insight Card: BPC-157 (\"Could BPC-157 help my knee pain from running?\")");
const r = await handle({ op: "interests_add", term: "BPC-157" }, ALEX_ID, deps);
line(`(followed interest: ${(r.body.interest as any).term})`);
const c = await handle({ op: "insight_card", compound: "BPC-157", question: "Could BPC-157 help my knee pain from running?" }, ALEX_ID, deps);
const card = c.body.card as any;
line(`Name: ${card.name}    Category: ${card.category}`);
line(`Human evidence: ${card.evidence.label}  [model claimed: ${card.evidence.claimed_level}; capped: ${card.evidence.capped}]`);
line(wrap(`Meaning: ${card.evidence.explanation}`));
line(wrap(`Cap: ${card.evidence.cap_reason}`));
line(`Mechanism:`); line(wrap(card.mechanism));
line(`Studied applications:`);
for (const a of card.studied_applications) {
  line(`  - ${a.application}: ${a.evidence.label}${a.evidence.capped ? ` (capped from ${a.evidence.claimed_level})` : ""}`);
  if (a.summary) line(wrap(a.summary, "      "));
  line(`      cites: ${a.citations.map((x: any) => `${x.source}:${x.id}`).join(", ") || "none"}`);
}
line(`Preclinical findings:`); line(wrap(card.preclinical_findings));
line(`Anecdotal reports — ${card.anecdotal_reports.label} (verified: ${card.anecdotal_reports.verified}):`);
line(wrap(card.anecdotal_reports.summary));
line(`  Biases: ${card.anecdotal_reports.biases.map((b: any) => b.name).join("; ")}`);
line(`Risks & unknowns:`); for (const x of card.risks_unknowns) line(wrap(`- ${x}`));
line(`Regulatory status: ${card.regulatory_status.fda}`); line(wrap(card.regulatory_status.summary));
line(wrap(`WADA: ${card.regulatory_status.wada.status} — ${card.regulatory_status.wada.note}`));
line(`Contraindications & interactions (cross-checked against current compounds/conditions):`);
for (const f of card.contraindications_interactions) line(wrap(`- [${f.kind} / ${f.severity}] ${f.with}: ${f.detail} (source: ${f.source})`));
line(`Compared with established approaches:`);
for (const e of card.established_approaches) line(wrap(`- ${e.name} (${e.kind}): ${e.note}`));
line(wrap(card.comparison_to_established));
line(`Personalized note:`); line(wrap(card.personalized_note));
line(`Dosing: ${card.dosing_note}`);
line(`Citations (verified against retrieved set; retrieved ${card.research_retrieved_at}):`);
for (const x of card.citations) line(wrap(`- [${x.source}:${x.id}] ${x.title} (${x.year ?? "n.d."}) — ${x.study_kind} — ${x.url}`));
line(`Dropped (not in retrieved set): ${card.dropped_citation_ids.join(", ")}`);
line(`Server guards applied: ${card.guard_applied.join(", ")}`);
line(`Sources checked: ${card.sources_checked.map((s: any) => `${s.source}=${s.ok ? "ok" : "failed"}${s.note ? ` (${s.note})` : ""}`).join(", ")}`);
line(`Last verified: ${card.last_verified_at}`);
line(wrap(card.disclaimer));

// 3. Discover
h("3) Proactive discovery (goals + pain log + routine + followed interests)");
deps.model = stubModel(DISCOVER_MODEL_OUTPUT).fn;
const d = await handle({ op: "discover", max: 8 }, ALEX_ID, deps);
line(wrap(String(d.body.summary)));
for (const s of d.body.suggestions as any[]) {
  line(`- ${s.name}  [${s.kind}]  ${s.evidence.label}${s.evidence.capped ? ` (capped from ${s.evidence.claimed_level})` : ""}`);
  line(wrap(`why: ${s.why_relevant}`, "      "));
  if (s.cautions.length) line(wrap(`cautions: ${s.cautions.join(" ")}`, "      "));
  for (const f of s.interaction_flags) line(wrap(`interaction: ${f.with} — ${f.detail}`, "      "));
  line(`      cites: ${s.citations.map((x: any) => `${x.source}:${x.id}`).join(", ") || "none"}`);
}
line(`Additional topics to research: ${(d.body.additional_topics as any[]).map((x) => `${x.name} ("${x.search_term}")`).join(", ")}`);
line(`Guards: ${(d.body.guard_applied as string[]).join(", ") || "none"}`);

// 4. Privacy
h("4) Privacy: every outbound research URL in this run");
const hosts = new Map<string, number>();
for (const u of fetch.urls) { const k = new URL(u).hostname; hosts.set(k, (hosts.get(k) ?? 0) + 1); }
line(`${fetch.urls.length} requests: ${[...hosts].map(([k, v]) => `${k} ×${v}`).join(", ")}`);
const terms = new Set(fetch.urls.map((u) => {
  const p = new URL(u).searchParams;
  return (p.get("term") ?? p.get("query.intr") ?? (p.get("search")?.match(/"([^"]+)"/)?.[1]) ?? (p.get("id") ? "(PubMed summary by IDs)" : "")).replace(/ AND .*$/, "");
}));
line(`Terms sent: ${[...terms].join(" | ")}`);
line(`Contains user id / name / health values: ${fetch.urls.some((u) => /a1e00000|Alex|Rivera|hypertension|92\.|203/.test(decodeURIComponent(u))) ? "YES (bug)" : "no"}`);
