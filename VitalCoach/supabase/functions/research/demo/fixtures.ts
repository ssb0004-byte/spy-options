// OFFLINE FIXTURES for tests and the demo. They follow the documented response shapes of
// PubMed E-utilities (esearch/esummary JSON), ClinicalTrials.gov API v2 (/api/v2/studies) and
// openFDA (/drug/label.json), but every ID and title is FICTIONAL ("[FIXTURE]" prefix, PMIDs in
// the 9xxxxxxx range, NCT9xxxxxxx). They are not real studies and must never be cited as such.
import type { FetchLike, FetchResponse } from "../lib/sources.ts";

interface PubmedRecord { title: string; pubdate: string; pubtype: string[] }
interface TermFixture {
  relevance: string[];
  high_quality: string[];
  animal_only: string[];
  trials: any[];
  label: any | null;
}

export const PUBMED: Record<string, PubmedRecord> = {
  // BPC-157: animal, lab, narrative review, one small human case series.
  "90000001": { title: "[FIXTURE] Pentadecapeptide BPC 157 accelerates Achilles tendon healing in rats", pubdate: "2019 Mar", pubtype: ["Journal Article"] },
  "90000002": { title: "[FIXTURE] BPC 157 and musculoskeletal soft tissue healing: a narrative review of preclinical data", pubdate: "2021 Jun 2", pubtype: ["Journal Article", "Review"] },
  "90000003": { title: "[FIXTURE] BPC 157 promotes tendon fibroblast outgrowth in vitro", pubdate: "2018", pubtype: ["Journal Article"] },
  "90000004": { title: "[FIXTURE] Systematic review of BPC 157 in rodent models of tendon and ligament injury", pubdate: "2023 Jan", pubtype: ["Journal Article", "Systematic Review"] },
  "90000005": { title: "[FIXTURE] Intra-articular BPC 157 for knee pain: a retrospective case series of 12 patients", pubdate: "2022 Nov", pubtype: ["Journal Article", "Case Reports"] },
  // Naproxen.
  "91000001": { title: "[FIXTURE] Oral NSAIDs for knee osteoarthritis pain: a network meta-analysis", pubdate: "2020 Feb", pubtype: ["Journal Article", "Meta-Analysis", "Systematic Review"] },
  "91000002": { title: "[FIXTURE] Naproxen versus placebo for acute musculoskeletal pain in adults: a randomized controlled trial", pubdate: "2018 May", pubtype: ["Journal Article", "Randomized Controlled Trial"] },
  // Exercise therapy for knee pain.
  "92000001": { title: "[FIXTURE] Exercise therapy for knee pain in adults: a systematic review and meta-analysis of randomized trials", pubdate: "2022 Apr", pubtype: ["Journal Article", "Meta-Analysis", "Systematic Review"] },
  "92000002": { title: "[FIXTURE] Hip and knee strengthening in runners with knee pain: a randomized controlled trial", pubdate: "2021 Sep", pubtype: ["Journal Article", "Randomized Controlled Trial"] },
  // Weight management and knee pain.
  "93000001": { title: "[FIXTURE] Weight loss and knee osteoarthritis pain: a systematic review", pubdate: "2021", pubtype: ["Journal Article", "Systematic Review"] },
  // Topical diclofenac.
  "94000001": { title: "[FIXTURE] Topical NSAIDs for chronic musculoskeletal pain in adults: a meta-analysis", pubdate: "2019 Jul", pubtype: ["Journal Article", "Meta-Analysis"] },
  // Running load / patellofemoral pain.
  "95000001": { title: "[FIXTURE] Gait retraining for patellofemoral pain in runners: a randomized controlled trial", pubdate: "2020 Oct", pubtype: ["Journal Article", "Randomized Controlled Trial"] },
  // Body composition.
  "96000001": { title: "[FIXTURE] Resistance training during caloric restriction preserves lean mass: a meta-analysis", pubdate: "2021 Dec", pubtype: ["Journal Article", "Meta-Analysis"] },
  "97000001": { title: "[FIXTURE] Higher-protein diets and body composition in adults: a meta-analysis of randomized trials", pubdate: "2020 Aug", pubtype: ["Journal Article", "Meta-Analysis"] },
  "98000001": { title: "[FIXTURE] Once-weekly semaglutide in adults with overweight or obesity: a randomized controlled trial", pubdate: "2021 Mar", pubtype: ["Journal Article", "Randomized Controlled Trial", "Multicenter Study"] },
  "98000002": { title: "[FIXTURE] GLP-1 receptor agonists for weight loss: a systematic review and meta-analysis", pubdate: "2022 Jan", pubtype: ["Journal Article", "Meta-Analysis", "Systematic Review"] },
  "99000001": { title: "[FIXTURE] Exercise therapy and chronic pain: an overview of systematic reviews", pubdate: "2017", pubtype: ["Journal Article", "Systematic Review"] },
};

const trial = (nct: string, title: string, status: string, hasResults: boolean, allocation = "RANDOMIZED", phases = ["PHASE2"]) => ({
  protocolSection: {
    identificationModule: { nctId: nct, briefTitle: title },
    statusModule: { overallStatus: status, startDateStruct: { date: "2022-03" }, completionDateStruct: { date: "2024-06" }, lastUpdatePostDateStruct: { date: "2025-01-15" } },
    designModule: { studyType: "INTERVENTIONAL", phases, designInfo: { allocation } },
  },
  hasResults,
});

const label = (setId: string, brand: string, generic: string, apps: string[], fields: Record<string, string[]>) => ({
  set_id: setId, id: `${setId}-v`, effective_time: "20240115", version: "12",
  openfda: { brand_name: [brand], generic_name: [generic], substance_name: [generic.toUpperCase()], product_type: ["HUMAN PRESCRIPTION DRUG"], application_number: apps, route: ["ORAL"] },
  ...fields,
});

export const LABELS = {
  naproxen: label("fixture-naproxen-0000", "FIXTURE-NAPROSYN", "NAPROXEN", ["ANDA000001"], {
    indications_and_usage: ["[FIXTURE] Relief of the signs and symptoms of osteoarthritis, rheumatoid arthritis, tendonitis, bursitis and acute pain."],
    boxed_warning: ["[FIXTURE] Cardiovascular thrombotic events and gastrointestinal bleeding, ulceration and perforation."],
    contraindications: ["[FIXTURE] Known hypersensitivity to naproxen. History of asthma or allergic-type reactions after taking aspirin or other NSAIDs. In the setting of coronary artery bypass graft surgery."],
    drug_interactions: ["[FIXTURE] ACE inhibitors, angiotensin receptor blockers, or beta-blockers: NSAIDs may diminish the antihypertensive effect. In patients who are elderly, volume-depleted, or with compromised renal function, coadministration may result in deterioration of renal function. Diuretics: reduced natriuretic effect. Lithium. Methotrexate. Anticoagulants: increased risk of serious bleeding."],
    warnings_and_cautions: ["[FIXTURE] Hypertension: NSAIDs can lead to new onset or worsening of preexisting hypertension. Renal toxicity in patients with impaired renal function, heart failure or liver dysfunction."],
  }),
  lisinopril: label("fixture-lisinopril-0000", "FIXTURE-PRINIVIL", "LISINOPRIL", ["NDA000002"], {
    indications_and_usage: ["[FIXTURE] Hypertension; heart failure; acute myocardial infarction."],
    contraindications: ["[FIXTURE] History of angioedema. Coadministration with aliskiren in patients with diabetes."],
    drug_interactions: ["[FIXTURE] Diuretics: hypotension. Potassium supplements and potassium-sparing diuretics: hyperkalemia. Non-steroidal anti-inflammatory agents including selective COX-2 inhibitors (NSAIDs): may result in deterioration of renal function and attenuate the antihypertensive effect. Lithium toxicity."],
  }),
  diclofenac: label("fixture-diclofenac-gel-0000", "FIXTURE-VOLTAREN GEL", "DICLOFENAC SODIUM", ["NDA000003"], {
    indications_and_usage: ["[FIXTURE] Relief of arthritis pain of the knee and hand."],
    drug_interactions: ["[FIXTURE] Concomitant use with oral NSAIDs, ACE inhibitors and anticoagulants: see full label."],
  }),
  semaglutide: label("fixture-semaglutide-0000", "FIXTURE-WEGOVY", "SEMAGLUTIDE", ["NDA000004"], {
    indications_and_usage: ["[FIXTURE] Chronic weight management in adults with obesity or overweight with a weight-related comorbidity."],
    boxed_warning: ["[FIXTURE] Risk of thyroid C-cell tumors."],
    drug_interactions: ["[FIXTURE] Insulin or insulin secretagogues: increased risk of hypoglycemia. Oral medications: delayed gastric emptying."],
  }),
};

export const TERMS: Record<string, TermFixture> = {
  "bpc-157": {
    relevance: ["90000001", "90000002", "90000003", "90000004", "90000005"], high_quality: ["90000004"], animal_only: ["90000001"],
    trials: [trial("NCT90000001", "[FIXTURE] Safety of BPC 157 in healthy volunteers", "COMPLETED", false, "NA", ["PHASE1"])], label: null,
  },
  "naproxen": { relevance: ["91000001", "91000002"], high_quality: ["91000001", "91000002"], animal_only: [], trials: [], label: LABELS.naproxen },
  "lisinopril": { relevance: [], high_quality: [], animal_only: [], trials: [], label: LABELS.lisinopril },
  "exercise therapy knee pain": { relevance: ["92000001", "92000002"], high_quality: ["92000001", "92000002"], animal_only: [], trials: [trial("NCT90000002", "[FIXTURE] Supervised exercise vs advice for knee pain", "COMPLETED", true)], label: null },
  "weight loss knee osteoarthritis pain": { relevance: ["93000001"], high_quality: ["93000001"], animal_only: [], trials: [], label: null },
  "topical diclofenac knee": { relevance: ["94000001"], high_quality: ["94000001"], animal_only: [], trials: [], label: LABELS.diclofenac },
  "patellofemoral pain runners exercise": { relevance: ["95000001"], high_quality: ["95000001"], animal_only: [], trials: [], label: null },
  "resistance training body composition weight loss": { relevance: ["96000001"], high_quality: ["96000001"], animal_only: [], trials: [], label: null },
  "high protein diet body composition": { relevance: ["97000001"], high_quality: ["97000001"], animal_only: [], trials: [], label: null },
  "semaglutide weight loss": { relevance: ["98000001", "98000002"], high_quality: ["98000001", "98000002"], animal_only: [], trials: [], label: LABELS.semaglutide },
  "exercise therapy chronic pain": { relevance: ["99000001"], high_quality: ["99000001"], animal_only: [], trials: [], label: null },
};

const ok = (body: unknown): FetchResponse => ({ ok: true, status: 200, json: async () => JSON.parse(JSON.stringify(body)) });
const notFound = (body: unknown): FetchResponse => ({ ok: false, status: 404, json: async () => body });

/** A fetch that serves the fixtures above from the real API URL shapes. Mutate TERMS to simulate new papers. */
export function fixtureFetch(terms: Record<string, TermFixture> = TERMS, pubmed: Record<string, PubmedRecord> = PUBMED): FetchLike & { urls: string[] } {
  const urls: string[] = [];
  const fn = (async (url: string) => {
    urls.push(url);
    const u = new URL(url);
    if (u.hostname === "eutils.ncbi.nlm.nih.gov" && u.pathname.endsWith("/esearch.fcgi")) {
      const term = u.searchParams.get("term") ?? "";
      const base = term.replace(/ AND .*$/, "").toLowerCase();
      const f = terms[base];
      const ids = !f ? [] : term.includes("[pt]") ? f.high_quality : term.includes("animals[mh]") ? f.animal_only : f.relevance;
      return ok({ header: { type: "esearch", version: "0.3" }, esearchresult: { count: String(ids.length), retmax: String(ids.length), retstart: "0", idlist: ids, translationset: [], querytranslation: term } });
    }
    if (u.hostname === "eutils.ncbi.nlm.nih.gov" && u.pathname.endsWith("/esummary.fcgi")) {
      const ids = (u.searchParams.get("id") ?? "").split(",").filter(Boolean);
      const result: Record<string, unknown> = { uids: ids.filter((id) => pubmed[id]) };
      for (const id of ids) {
        const r = pubmed[id];
        if (!r) continue;
        result[id] = { uid: id, pubdate: r.pubdate, epubdate: "", source: "Fixture J", authors: [{ name: "Fixture A", authtype: "Author", clusterid: "" }],
          lastauthor: "Fixture A", title: r.title, pubtype: r.pubtype, fulljournalname: "Journal of Fixtures", sortpubdate: `${r.pubdate.slice(0, 4)}/01/01 00:00` };
      }
      return ok({ header: { type: "esummary", version: "0.3" }, result });
    }
    if (u.hostname === "clinicaltrials.gov") {
      const f = terms[(u.searchParams.get("query.intr") ?? "").toLowerCase()];
      return ok({ studies: f?.trials ?? [], totalCount: f?.trials.length ?? 0 });
    }
    if (u.hostname === "api.fda.gov") {
      const m = (u.searchParams.get("search") ?? "").match(/"([^"]+)"/);
      const f = m ? terms[m[1].toLowerCase()] : undefined;
      if (f?.label) return ok({ meta: { disclaimer: "fixture", last_updated: "2026-10-01", results: { skip: 0, limit: 5, total: 1 } }, results: [f.label] });
      return notFound({ error: { code: "NOT_FOUND", message: "No matches found!" } });
    }
    return { ok: false, status: 404, json: async () => ({}) };
  }) as FetchLike & { urls: string[] };
  fn.urls = urls;
  return fn;
}

/** In-memory ResearchCache. */
export function memoryCache() {
  const store = new Map<string, { payload: any; fetched_at: string; source: string }>();
  return {
    store,
    async get(key: string, maxAgeMs: number, now: Date) {
      const e = store.get(key);
      return e && now.getTime() - Date.parse(e.fetched_at) <= maxAgeMs ? { payload: e.payload, fetched_at: e.fetched_at } : null;
    },
    async put(key: string, source: string, _query: string, payload: any, fetchedAt: string) {
      store.set(key, { payload, fetched_at: fetchedAt, source });
    },
  };
}

// ---------------------------------------------------------------------------------------------
// Fictional user profile and an in-memory ResearchDb (tests + demo).
// ---------------------------------------------------------------------------------------------
import type { Rows } from "../../coach/lib/context.ts";
import type { ModelConfig } from "../../coach/lib/openai.ts";
import type { Interest, ResearchDb, StoredAlert, StoredInsight } from "../lib/handler.ts";

export const ALEX_ID = "a1e00000-0000-4000-8000-00000000a1e0";

/** FICTIONAL: Alex Rivera, 42, knee pain after running; takes lisinopril and vitamin D3. */
export function alexRows(): Rows {
  const day = (d: number) => `2026-10-${String(d).padStart(2, "0")}T07:30:00Z`;
  return {
    profile: { display_name: "Alex Rivera", date_of_birth: "1984-05-02", physiological_sex: "male", height_cm: 178, activity_level: "active",
      medical_conditions: ["hypertension"], allergies: [], injuries: ["right knee pain after running"] },
    preferences: { unit_system: "imperial", coach_personality: "balanced" },
    goals: [{ goal: "reduced_pain", is_active: true }, { goal: "fat_loss", is_active: true }],
    measurements: [1, 4, 7, 10, 13].map((d) => ({ kind: "body_mass", value: 92.4 - d * 0.05, start_at: day(d), quality: "measured", source_name: "Scale" })),
    substances: [
      { id: "s-lis", name: "Lisinopril", category: "prescription", status: "active", is_prescribed: true, indication: "blood pressure" },
      { id: "s-vd3", name: "Vitamin D3", category: "vitamin_mineral", status: "active" },
    ],
    regimens: [],
    administrations: [],
    symptoms: [],
    pain: [{ recorded_at: day(9), location: "right knee", severity: 5 }, { recorded_at: day(12), location: "right knee", severity: 4 }],
    adverseEffects: [],
    memories: [],
  };
}

export const testConfig: ModelConfig = { prompt_version: "test", chat_model: "test-model", reasoning_effort: "low", max_output_tokens: 1200,
  daily_token_limit_per_user: 60_000, daily_request_limit_per_user: 60, monthly_token_limit_global: 5_000_000 };

export function fakeResearchDb(opts: { consent?: boolean; rows?: Rows; usage?: Partial<{ userTokensToday: number; userRequestsToday: number; userRequestsLastMinute: number; globalTokensThisMonth: number }> } = {}) {
  const state = { insights: [] as (StoredInsight & { created_at: string })[], interests: [] as Interest[], alerts: [] as StoredAlert[], usage: [] as any[], n: 0 };
  const id = () => `00000000-0000-4000-8000-${String(++state.n).padStart(12, "0")}`;
  const db: ResearchDb = {
    aiConsentGranted: async () => opts.consent ?? true,
    loadRows: async () => opts.rows ?? alexRows(),
    config: async () => testConfig,
    usage: async () => ({ userTokensToday: 0, userRequestsToday: 0, userRequestsLastMinute: 0, globalTokensThisMonth: 0, ...(opts.usage ?? {}) }),
    recordUsage: async (u, d, i, o) => { state.usage.push({ u, d, i, o }); },
    findInsight: async (_u, kind, key, hash, since) =>
      state.insights.find((x) => x.kind === kind && x.compound_key === key && x.context_hash === hash && x.created_at >= since) ?? null,
    saveInsight: async (_u, row) => {
      const x = { id: id(), kind: row.kind, compound_key: row.compound_key, context_hash: row.context_hash, payload: row.payload, created_at: row.last_verified_at };
      state.insights.push(x);
      return x;
    },
    listInterests: async () => state.interests.map((i) => ({ ...i })),
    addInterest: async (_u, row) => { const x: Interest = { id: id(), ...row, last_checked_at: null, last_seen: null }; state.interests.push(x); return x; },
    removeInterest: async (_u, iid) => { const before = state.interests.length; state.interests = state.interests.filter((i) => i.id !== iid); return state.interests.length < before; },
    updateInterest: async (_u, iid, lastSeen, at) => { const i = state.interests.find((x) => x.id === iid)!; i.last_seen = lastSeen; i.last_checked_at = at; },
    saveAlerts: async (_u, interestId, drafts) => {
      const saved = drafts.map((d) => ({ id: id(), interest_id: interestId, kind: d.kind, title: d.title, summary: d.summary, citation: d.citation, seen_at: null }));
      state.alerts.push(...saved);
      return saved;
    },
  };
  return { db, state };
}

/** A stubbed model that returns fixed JSON and records the request bodies. */
export function stubModel(output: Record<string, unknown> | ((body: any) => Record<string, unknown>)) {
  const calls: any[] = [];
  const fn = async (body: Record<string, unknown>) => {
    calls.push(body);
    const o = typeof output === "function" ? output(body) : output;
    return { text: JSON.stringify(o), inputTokens: 1500, outputTokens: 600, status: "completed" };
  };
  return { fn, calls };
}

/** Stubbed BPC-157 card output, deliberately including things the server must remove. */
export const BPC157_MODEL_OUTPUT = {
  name: "BPC-157",
  category: "peptide_investigational",
  mechanism: "A synthetic 15-amino-acid peptide fragment. In animal and cell studies it has been linked to blood-vessel growth and tendon cell activity; how (or whether) this applies in people is unknown.",
  studied_applications: [
    { application: "Tendon and ligament healing", evidence_level: "established_human", summary: "Rodent studies and a systematic review of rodent studies report faster tendon healing. Typical protocol is 250 mcg injected subcutaneously twice daily.", cited_ids: ["90000001", "90000004"] },
    { application: "Knee pain", evidence_level: "preliminary_human", summary: "One small retrospective case series without a control group reported less pain.", cited_ids: ["90000005", "PMID: 12345678"] },
  ],
  evidence_level: "established_human",
  evidence_explanation: "Many studies show it works for tendon healing.",
  preclinical_findings: "In rats, tendon and ligament injuries healed faster; lab studies show increased tendon fibroblast outgrowth.",
  anecdotal_summary: "Online communities report reduced joint pain. Users often take BPC-157 daily in 4-week-on cycles.",
  risks_unknowns: [
    "No controlled human safety data; long-term effects are unknown.",
    "Products sold as 'research chemicals' may be mislabeled or contaminated.",
    "It is completely safe for most people.",
  ],
  interaction_considerations: ["No interaction studies exist with lisinopril or vitamin D3; ask a pharmacist."],
  comparison_to_established: "For knee pain after running, exercise therapy, load management and weight management have much stronger human evidence than BPC-157.",
  personalized_note: "Because you take lisinopril, review any new compound with your prescriber.",
  cited_ids: ["90000001", "90000004", "90000005", "99999999"],
  safety: { needs_clinician: true, topics: ["peptide"] },
};

export const DISCOVER_MODEL_OUTPUT = {
  summary: "For knee pain after running and body-composition goals, exercise-based options have the strongest evidence.",
  suggestions: [
    { candidate_id: "knee_exercise_therapy", why_relevant: "You logged right-knee pain and want less pain.", evidence_level: "established_human", evidence_explanation: "Meta-analysis of randomized trials.", cautions: ["Start gradually; a physical therapist can tailor it."], cited_ids: ["92000001", "92000002"] },
    { candidate_id: "knee_topical_nsaid", why_relevant: "Topical NSAIDs act locally with lower whole-body exposure.", evidence_level: "established_human", evidence_explanation: "Meta-analysis.", cautions: ["Use per label; you take lisinopril — ask a pharmacist. Apply 4 g four times daily."], cited_ids: ["94000001"] },
    { candidate_id: "fatloss_resistance", why_relevant: "Supports body composition while losing fat.", evidence_level: "established_human", evidence_explanation: "Meta-analysis.", cautions: [], cited_ids: ["96000001"] },
    { candidate_id: "interest_bpc_157", why_relevant: "You follow BPC-157.", evidence_level: "moderate_human", evidence_explanation: "Some studies.", cautions: ["Investigational; not FDA-approved."], cited_ids: ["90000001", "90000005"] },
  ],
  additional_topics: [{ name: "Sleep and pain", search_term: "sleep chronic pain", category: "lifestyle", why: "Poor sleep can amplify pain." }],
};
