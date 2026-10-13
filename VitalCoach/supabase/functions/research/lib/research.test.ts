// Run: node --experimental-strip-types --no-warnings --test VitalCoach/supabase/functions/research/lib/research.test.ts
// Fully offline: research APIs are served from fixtures with the documented response shapes.
import { test } from "node:test";
import assert from "node:assert/strict";
import { capEvidence, classifyPubmed, supportedLevel, verifyCitations, anecdotalBlock, type Citation } from "./evidence.ts";
import { sanitizeTerm, pubmedSearchUrl, ctgovUrl, openFdaLabelUrl, cacheKey, parsePubmedSummary, parseCtgov, parseOpenFdaLabel, retrieveEvidence } from "./sources.ts";
import { crossCheck } from "./interactions.ts";
import { meaningfulUpdates, snapshotOf } from "./updates.ts";
import { buildCandidates } from "./candidates.ts";
import { CARD_SCHEMA, DISCOVER_SCHEMA, parseCard } from "./prompt.ts";
import { handle, type ResearchDeps } from "./handler.ts";
import { screenRedFlags, stripDosing, containsDosing } from "../../coach/lib/safety.ts";
import { buildContext } from "../../coach/lib/context.ts";
import {
  ALEX_ID, alexRows, BPC157_MODEL_OUTPUT, DISCOVER_MODEL_OUTPUT, fakeResearchDb, fixtureFetch, memoryCache, PUBMED, stubModel, TERMS,
} from "../demo/fixtures.ts";

const NOW = new Date("2026-10-14T12:00:00Z");
const cite = (id: string, kind: Citation["study_kind"], source: Citation["source"] = "pubmed"): Citation =>
  ({ source, id, title: `t${id}`, year: 2020, url: `u${id}`, publication_types: [], study_kind: kind, retrieved_at: NOW.toISOString() });

function deps(over: Partial<ResearchDeps> & { dbOpts?: Parameters<typeof fakeResearchDb>[0]; model?: ResearchDeps["model"] } = {}) {
  const { db, state } = fakeResearchDb(over.dbOpts);
  const fetch = fixtureFetch();
  const cache = memoryCache();
  const model = stubModel(BPC157_MODEL_OUTPUT);
  const d: ResearchDeps = { db, cache, fetch, model: over.model ?? model.fn, now: () => NOW, ...over };
  return { d, state, fetch, cache, model };
}

// ---------- evidence ----------
test("evidence cap: cannot claim established human evidence with only animal studies", () => {
  const animalOnly = [cite("1", "animal"), cite("2", "animal")];
  const a = capEvidence("established_human", animalOnly);
  assert.equal(a.level, "preclinical_animal");
  assert.equal(a.capped, true);
  assert.match(a.cap_reason!, /Animal studies only/);
  assert.equal(capEvidence("established_human", [cite("3", "rct")]).level, "moderate_human");
  assert.equal(capEvidence("established_human", [cite("3", "rct"), cite("4", "rct")]).level, "established_human");
  assert.equal(capEvidence("established_human", [cite("5", "meta_analysis")]).capped, false);
  assert.equal(capEvidence("moderate_human", [cite("6", "case_report")]).level, "preliminary_human");
  assert.equal(capEvidence("preliminary_human", []).level, "insufficient");
  assert.equal(capEvidence("preliminary_human", [], { hasAnecdotes: true }).level, "anecdotal_community");
  assert.equal(capEvidence("anecdotal_community", []).level, "anecdotal_community"); // never needs citations
  assert.equal(capEvidence("made_up", [cite("5", "meta_analysis")]).level, "insufficient");
  assert.equal(capEvidence("established_human", [cite("x", "regulatory_label", "fda_label")]).level, "established_human");
  assert.equal(capEvidence("moderate_human", [cite("n", "trial_registration", "clinicaltrials")]).level, "insufficient"); // registration ≠ evidence
});

test("study classification uses pubtypes, MeSH animal tagging and title keywords", () => {
  assert.equal(classifyPubmed(["Journal Article", "Systematic Review"], "Systematic review of BPC 157 in rodent models", false), "animal");
  assert.equal(classifyPubmed(["Randomized Controlled Trial"], "Exercise in adults with knee pain", false), "rct");
  assert.equal(classifyPubmed(["Journal Article"], "Effect on tendon fibroblasts in vitro", false), "in_vitro");
  assert.equal(classifyPubmed(["Journal Article"], "Tendon healing outcomes", true), "animal");
  assert.equal(classifyPubmed(["Journal Article", "Meta-Analysis"], "Topical NSAIDs in adults", false), "meta_analysis");
  assert.equal(classifyPubmed(["Case Reports"], "Knee pain in 12 patients", false), "case_report");
  assert.equal(supportedLevel([cite("a", "review")]).level, "insufficient");
});

test("API response parsers follow the documented shapes", () => {
  const sum = { result: { uids: ["90000001", "90000005"], "90000001": { uid: "90000001", pubdate: "2019 Mar", title: "Healing in <i>rats</i>", pubtype: ["Journal Article"] },
    "90000005": { uid: "90000005", pubdate: "2022 Nov", title: "Case series of 12 patients", pubtype: ["Case Reports"] } } };
  const cs = parsePubmedSummary(sum, new Set(), NOW.toISOString());
  assert.deepEqual(cs.map((c) => [c.id, c.year, c.study_kind, c.title]), [["90000001", 2019, "animal", "Healing in rats"], ["90000005", 2022, "case_report", "Case series of 12 patients"]]);
  assert.equal(cs[0].url, "https://pubmed.ncbi.nlm.nih.gov/90000001/");
  const ct = parseCtgov({ studies: TERMS["exercise therapy knee pain"].trials }, NOW.toISOString());
  assert.equal(ct.citations[0].study_kind, "trial_with_results");
  assert.equal(ct.citations[0].url, "https://clinicaltrials.gov/study/NCT90000002");
  const fda = parseOpenFdaLabel({ results: [TERMS.naproxen.label] }, NOW.toISOString())!;
  assert.equal(fda.label.approved, true);
  assert.equal(fda.citation.study_kind, "regulatory_label");
  assert.equal(fda.citation.year, 2024);
  assert.equal(parseOpenFdaLabel({ results: [] }, NOW.toISOString()), null);
});

// ---------- citations ----------
test("invented citations are dropped; only retrieved IDs survive", async () => {
  const retrieved = [cite("90000001", "animal"), cite("NCT90000001", "trial_registration", "clinicaltrials")];
  const v = verifyCitations(["PMID: 90000001", "99999999", "nct90000001", 42], retrieved);
  assert.deepEqual(v.citations.map((c) => c.id), ["90000001", "NCT90000001"]);
  assert.deepEqual(v.dropped, ["99999999"]);

  const { d } = deps();
  const r = await handle({ op: "insight_card", compound: "BPC-157" }, ALEX_ID, d);
  const card = r.body.card as any;
  const ids = card.citations.map((c: Citation) => c.id);
  assert.ok(!ids.includes("99999999") && !ids.includes("12345678"));
  assert.ok(card.dropped_citation_ids.includes("99999999") && card.dropped_citation_ids.includes("PMID: 12345678"));
  assert.ok(card.guard_applied.includes("invented_citations_dropped"));
  for (const c of card.citations) assert.ok(PUBMED[c.id] || c.source !== "pubmed", "every PubMed citation is from the retrieved set");
});

test("BPC-157 card: evidence capped (animal + one case series ≠ established), anecdotes unverified, regulatory status from openFDA", async () => {
  const { d } = deps();
  const r = await handle({ op: "insight_card", compound: "BPC-157", question: "Could BPC-157 help my knee?" }, ALEX_ID, d);
  assert.equal(r.status, 200);
  const card = r.body.card as any;
  assert.equal(card.evidence.claimed_level, "established_human");
  assert.equal(card.evidence.level, "preliminary_human"); // the one case series is the strongest human evidence
  assert.equal(card.evidence.capped, true);
  const tendon = card.studied_applications.find((a: any) => a.application.startsWith("Tendon"));
  assert.equal(tendon.evidence.level, "preclinical_animal"); // SR of rodent studies is still animal evidence
  assert.equal(card.anecdotal_reports.verified, false);
  assert.match(card.anecdotal_reports.label, /Unverified/);
  const biases = card.anecdotal_reports.biases.map((b: any) => b.name).join(" | ");
  for (const b of ["Placebo", "Selection", "Survivorship", "contamination", "Conflicts of interest"]) assert.match(biases, new RegExp(b, "i"));
  assert.equal(card.regulatory_status.fda, "no_label_found");
  assert.equal(card.regulatory_status.wada.status, "unknown");
  assert.ok(card.established_approaches.some((a: any) => /physical therapy/i.test(a.name)), "compared vs established approaches for knee pain");
  assert.ok(card.last_verified_at && card.research_retrieved_at);
  assert.equal(card.risks_unknowns.some((x: string) => /completely safe/i.test(x)), false, "absolute safety claims removed");
});

// ---------- dosing ----------
test("no dosing in output: BPC-157 protocol and cycle text are stripped", async () => {
  const { d } = deps();
  const r = await handle({ op: "insight_card", compound: "BPC-157" }, ALEX_ID, d);
  const card = r.body.card as any;
  const { dosing_note, ...rest } = card;
  const text = JSON.stringify(rest);
  assert.doesNotMatch(text, /\bmcg\b|twice daily|4-week-on|cycles/i);
  assert.ok(card.guard_applied.includes("dosing_removed"));
  assert.match(dosing_note, /intentionally not provided/);
  assert.match(card.anecdotal_reports.summary, /reduced joint pain/); // the non-dosing sentence is kept
  // Unit level: dose amounts, per-kg, and compound + frequency/cycle are removed; non-drug frequency is kept.
  assert.equal(containsDosing("Studies used 10 µg/kg in rats."), true);
  assert.equal(containsDosing("Inject it every other day."), true);
  assert.equal(containsDosing("Users run BPC-157 in cycles.", ["BPC-157"]), true);
  assert.equal(containsDosing("Exercise therapy three times a week reduced pain."), false);
  assert.equal(stripDosing("Helpful context. Take 500 mg twice daily. More context.").text, "Helpful context. More context.");
});

// ---------- triage ----------
test("red-flag triage stops compound discussion for a knee that can't bear weight", async () => {
  const { d, fetch, model } = deps();
  const r = await handle({ op: "insight_card", compound: "BPC-157", question: "I twisted my knee playing soccer, heard a pop and now I can't bear weight. Would BPC-157 help?" }, ALEX_ID, d);
  assert.equal(r.status, 200);
  assert.equal(r.body.stopped, true);
  assert.equal(r.body.card, null);
  const triage = r.body.triage as any;
  assert.equal(triage.level, "urgent");
  assert.ok(triage.flags.some((f: any) => f.id === "cant_bear_weight"));
  assert.match(triage.message, /assessed today/);
  assert.equal(fetch.urls.length, 0, "no research API calls");
  assert.equal(model.calls.length, 0, "no model call");
  // Screen details.
  assert.equal(screenRedFlags("Knee aches after long runs, no swelling, no fever, no numbness.").level, "none");
  assert.equal(screenRedFlags("My knee keeps giving way").level, "see_clinician");
  assert.equal(screenRedFlags("My knee gave way after I fell").level, "urgent");
  assert.equal(screenRedFlags("Hot swollen knee and a fever").stop, true);
  assert.equal(screenRedFlags("I have chest pain").level, "emergency");
  assert.equal(screenRedFlags("I’m unable to walk on it").flags[0].id, "cant_bear_weight");
});

// ---------- privacy ----------
test("outbound research URLs contain only compound/topic terms — no user data", async () => {
  const { d, fetch } = deps();
  await handle({ op: "insight_card", compound: "BPC-157", question: "My right knee hurts after running 5 miles, I weigh 203 lb and my email is alex@example.com" }, ALEX_ID, d);
  await handle({ op: "interests_add", term: "BPC-157" }, ALEX_ID, d);
  d.model = stubModel(DISCOVER_MODEL_OUTPUT).fn;
  await handle({ op: "discover", concern: "knee pain after running" }, ALEX_ID, d);
  assert.ok(fetch.urls.length > 5);
  const forbidden = [ALEX_ID, "Alex", "Rivera", "alex@example.com", "203", "92.", "hurts", "5 miles", "hypertension", "1984", "right knee", "blood pressure"];
  for (const url of fetch.urls) {
    const decoded = decodeURIComponent(url);
    for (const f of forbidden) assert.ok(!decoded.includes(f), `URL leaks "${f}": ${decoded}`);
    assert.match(new URL(url).hostname, /^(eutils\.ncbi\.nlm\.nih\.gov|clinicaltrials\.gov|api\.fda\.gov)$/);
  }
  assert.equal(sanitizeTerm("BPC-157 alex@example.com"), null);
  assert.equal(sanitizeTerm("weight 92 kg"), null);
  assert.equal(sanitizeTerm(ALEX_ID), null);
  assert.equal(sanitizeTerm("  Vitamin   D3 "), "Vitamin D3");
  // API keys never end up in cache keys.
  assert.equal(cacheKey(pubmedSearchUrl("creatine", "relevance", "SECRET")).includes("SECRET"), false);
  assert.match(ctgovUrl("creatine"), /query\.intr=creatine/);
  assert.match(decodeURIComponent(openFdaLabelUrl("naproxen")), /openfda\.generic_name:"naproxen"/);
});

// ---------- cache ----------
test("shared research cache: second retrieval makes no network calls; card cache avoids the model", async () => {
  const { d, fetch, model, cache } = deps();
  await handle({ op: "insight_card", compound: "BPC-157" }, ALEX_ID, d);
  const firstCalls = fetch.urls.length;
  assert.ok(firstCalls >= 5);
  assert.ok([...cache.store.keys()].every((k) => !k.includes("api_key")));
  await handle({ op: "insight_card", compound: "BPC-157", force_refresh: true }, ALEX_ID, d);
  assert.equal(fetch.urls.length, firstCalls, "forced regeneration re-used cached API responses");
  assert.equal(model.calls.length, 2);
  const third = await handle({ op: "insight_card", compound: "bpc-157" }, ALEX_ID, d);
  assert.equal(third.body.cached, true);
  assert.equal(model.calls.length, 2, "cached card: no model call");
  // Expired entries are refetched.
  const later = { ...d, now: () => new Date(NOW.getTime() + 8 * 86_400_000) };
  await retrieveEvidence("BPC-157", { fetch: d.fetch, cache: d.cache, now: later.now });
  assert.ok(fetch.urls.length > firstCalls);
});

// ---------- interactions ----------
test("interactions are cross-checked against current compounds and conditions", async () => {
  const { d } = deps({ model: stubModel({ ...BPC157_MODEL_OUTPUT, name: "Naproxen", category: "otc", cited_ids: ["91000001"], studied_applications: [] }).fn });
  const r = await handle({ op: "insight_card", compound: "naproxen", question: "Can I take naproxen for my knee?" }, ALEX_ID, d);
  const flags = (r.body.card as any).contraindications_interactions as any[];
  assert.ok(flags.some((f) => f.with === "Lisinopril" && f.source === "curated_rule" && /kidney/.test(f.detail)), "curated NSAID + ACE inhibitor rule");
  assert.ok(flags.some((f) => f.with === "Lisinopril" && f.source.startsWith("fda_label:")), "label text cross-check");
  assert.ok(flags.some((f) => f.kind === "condition" && f.with === "hypertension"));
  assert.equal((r.body.card as any).regulatory_status.fda, "approved_label");
  assert.equal((r.body.card as any).evidence.level, "established_human"); // meta-analysis cited

  // Investigational compound without a label: explicit "no data" flag naming current compounds.
  const bpc = crossCheck("BPC-157", null, new Map(), { compounds: [{ name: "Lisinopril", category: "prescription" }, { name: "Vitamin D3", category: "vitamin_mineral" }], conditions: [], allergies: [] });
  assert.equal(bpc.length, 1);
  assert.equal(bpc[0].kind, "no_data");
  assert.match(bpc[0].detail, /not evidence of safety/);
  assert.match(bpc[0].with, /Lisinopril, Vitamin D3/);
});

// ---------- updates ----------
test("meaningful-update filter ignores ordinary papers but alerts on a new meta-analysis", async () => {
  const base = { term: "x", trials: [], label: null, sources: [], retrieved_at: NOW.toISOString() };
  const prev = snapshotOf({ ...base, citations: [cite("1", "rct")] }, null);
  assert.deepEqual(meaningfulUpdates("BPC-157", null, { ...base, citations: [cite("9", "meta_analysis")] }), [], "first check is a baseline");
  const ordinary = meaningfulUpdates("BPC-157", prev, { ...base, citations: [cite("1", "rct"), cite("2", "case_report"), cite("3", "animal"), cite("4", "review"), cite("5", "other")] });
  assert.deepEqual(ordinary, []);
  const meta = meaningfulUpdates("BPC-157", prev, { ...base, citations: [cite("1", "rct"), cite("6", "meta_analysis"), cite("7", "in_vitro")] });
  assert.deepEqual(meta.map((a) => a.kind), ["new_meta_analysis"]);

  // End to end through check_updates with the handler.
  const { d, state } = deps();
  await handle({ op: "interests_add", term: "BPC-157" }, ALEX_ID, d);
  const first = await handle({ op: "check_updates" }, ALEX_ID, d);
  assert.equal((first.body.alerts as any[]).length, 0);
  // A new animal study and a new meta-analysis appear the next day.
  PUBMED["90000010"] = { title: "[FIXTURE] BPC 157 in a mouse model of muscle injury", pubdate: "2026 Oct", pubtype: ["Journal Article"] };
  PUBMED["90000011"] = { title: "[FIXTURE] BPC 157 for musculoskeletal pain in adults: a meta-analysis", pubdate: "2026 Oct", pubtype: ["Journal Article", "Meta-Analysis"] };
  TERMS["bpc-157"].relevance.push("90000010", "90000011");
  TERMS["bpc-157"].high_quality.push("90000011");
  try {
    const next = { ...d, now: () => new Date(NOW.getTime() + 2 * 86_400_000) };
    const second = await handle({ op: "check_updates" }, ALEX_ID, next);
    assert.deepEqual((second.body.alerts as any[]).map((a) => [a.kind, a.citation.id]), [["new_meta_analysis", "90000011"]]);
    assert.equal(state.alerts.length, 1);
    const again = await handle({ op: "check_updates" }, ALEX_ID, next);
    assert.equal(again.body.checked, 0, "rate-limited to one check per 12 hours");
  } finally {
    TERMS["bpc-157"].relevance.splice(-2);
    TERMS["bpc-157"].high_quality.splice(-1);
    delete PUBMED["90000010"]; delete PUBMED["90000011"];
  }
});

// ---------- consent ----------
test("AI consent is required before any research API or model call", async () => {
  const { d, fetch, model } = deps({ dbOpts: { consent: false } });
  for (const req of [{ op: "insight_card", compound: "BPC-157" }, { op: "discover" }, { op: "check_updates" }, { op: "interests_add", term: "BPC-157" }] as const) {
    const r = await handle(req as any, ALEX_ID, d);
    assert.equal(r.status, 403, req.op);
    assert.equal(r.body.error, "consent_required");
  }
  assert.equal(fetch.urls.length, 0);
  assert.equal(model.calls.length, 0);
  assert.equal((await handle({ op: "interests_list" }, ALEX_ID, d)).status, 200, "listing works without consent");
  assert.equal((await handle({ op: "nope" } as any, ALEX_ID, d)).status, 400);
});

test("budget limits are enforced before research APIs or the model are called", async () => {
  const { d, fetch, model } = deps({ dbOpts: { usage: { userTokensToday: 59_000 } } });
  const r = await handle({ op: "insight_card", compound: "creatine" }, ALEX_ID, d);
  assert.equal(r.status, 429);
  assert.equal(fetch.urls.length + model.calls.length, 0);
});

// ---------- discover ----------
test("discover includes non-drug interventions, caps evidence, strips dosing and records usage", async () => {
  const { d, state } = deps({ model: stubModel(DISCOVER_MODEL_OUTPUT).fn });
  await handle({ op: "interests_add", term: "BPC-157" }, ALEX_ID, d);
  const r = await handle({ op: "discover", max: 8 }, ALEX_ID, d);
  assert.equal(r.status, 200);
  const s = r.body.suggestions as any[];
  assert.ok(s.some((x) => x.kind === "non_drug" && x.evidence.level === "established_human"));
  const bpc = s.find((x) => x.candidate_id === "interest_bpc_157");
  assert.equal(bpc.evidence.level, "preliminary_human"); // claimed moderate; only a case series + animal study cited
  const nsaid = s.find((x) => x.candidate_id === "knee_topical_nsaid");
  assert.doesNotMatch(JSON.stringify(nsaid.cautions), /4 g|four times daily/);
  assert.ok(nsaid.interaction_flags.length > 0, "drug candidates are cross-checked against current compounds");
  assert.equal((r.body.additional_topics as any[])[0].search_term, "sleep chronic pain");
  assert.equal(state.usage.length, 1);

  // Even if the model returns only drug options, non-drug options are added.
  const drugOnly = { ...DISCOVER_MODEL_OUTPUT, suggestions: [DISCOVER_MODEL_OUTPUT.suggestions[1]] };
  const d2 = deps({ model: stubModel(drugOnly).fn }).d;
  const r2 = await handle({ op: "discover" }, ALEX_ID, d2);
  assert.ok((r2.body.suggestions as any[]).some((x) => x.kind === "non_drug" && x.summarized_by_model === false));

  // Candidate selection keeps at least half non-drug.
  const ctx = buildContext(alexRows(), "2026-10-14", "UTC");
  const c = buildCandidates(ctx, [{ term: "BPC-157" }], 6);
  assert.ok(c.filter((x) => x.kind === "non_drug").length >= 3);

  // Red flags in the concern stop discovery.
  const d3 = deps({ model: stubModel(DISCOVER_MODEL_OUTPUT).fn });
  const r3 = await handle({ op: "discover", concern: "my knee locked up after a fall and I can't walk" }, ALEX_ID, d3.d);
  assert.equal(r3.body.stopped, true);
  assert.equal(d3.fetch.urls.length, 0);
});

// ---------- schemas ----------
test("research schemas are strict-mode compatible and parsing clamps output", () => {
  const check = (s: any) => {
    if (s.anyOf) return s.anyOf.forEach(check);
    if (s.type === "object") {
      assert.equal(s.additionalProperties, false);
      assert.deepEqual([...s.required].sort(), Object.keys(s.properties).sort());
      Object.values(s.properties).forEach(check);
    }
    if (s.type === "array") check(s.items);
  };
  check(CARD_SCHEMA);
  check(DISCOVER_SCHEMA);
  assert.equal(parseCard("nope"), null);
  assert.equal(parseCard(JSON.stringify({ ...BPC157_MODEL_OUTPUT, category: "weird" }))!.category, "other");
});

test("interests: add (dedupe, sanitized), list and remove", async () => {
  const { d } = deps();
  const a = await handle({ op: "interests_add", term: " BPC-157 " }, ALEX_ID, d);
  const b = await handle({ op: "interests_add", term: "bpc-157" }, ALEX_ID, d);
  assert.equal(a.body.created, true);
  assert.equal(b.body.created, false);
  assert.equal((await handle({ op: "interests_add", term: "alex@example.com" }, ALEX_ID, d)).status, 400);
  const list = await handle({ op: "interests_list" }, ALEX_ID, d);
  assert.equal((list.body.interests as any[]).length, 1);
  assert.equal("last_seen" in (list.body.interests as any[])[0], false);
  const id = (a.body.interest as any).id;
  assert.equal((await handle({ op: "interests_remove", id }, ALEX_ID, d)).body.removed, true);
  assert.equal((await handle({ op: "interests_remove", id: "not-a-uuid" }, ALEX_ID, d)).status, 400);
});
