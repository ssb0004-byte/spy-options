// Retrieval from free public research sources: PubMed E-utilities, ClinicalTrials.gov API v2
// and openFDA drug labels. Privacy rule: outbound URLs contain ONLY the sanitized compound/topic
// term and fixed parameters — never user identifiers, health values or free-text questions.
// Every response is cached in a shared table (research_cache) to minimize API calls.
import { classifyPubmed, type Citation, type StudyKind } from "./evidence.ts";

export interface FetchResponse { ok: boolean; status: number; json(): Promise<any> }
export type FetchLike = (url: string, init?: { headers?: Record<string, string>; signal?: AbortSignal }) => Promise<FetchResponse>;

export interface CacheEntry { payload: any; fetched_at: string }
export interface ResearchCache {
  get(key: string, maxAgeMs: number, now: Date): Promise<CacheEntry | null>;
  put(key: string, source: string, query: string, payload: any, fetchedAt: string): Promise<void>;
}

export const DEFAULT_TTL_MS = 7 * 86_400_000;
const EUTILS = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils";
const TOOL = "vitalcoach";

/**
 * Normalizes a compound/topic term for outbound queries. Returns null when the term is empty,
 * too long, or looks like it carries personal data (emails, phone numbers, UUIDs, long digit
 * runs, measurements with units of body data).
 */
export function sanitizeTerm(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const t = raw.normalize("NFKC").replace(/[\u0000-\u001f]/g, " ").replace(/\s+/g, " ").trim();
  if (t.length < 2 || t.length > 80) return null;
  if (/@|https?:|www\./i.test(t)) return null;
  if (/[0-9a-f]{8}-[0-9a-f]{4}-/i.test(t)) return null;
  if (/\d{5,}/.test(t.replace(/[-\s]/g, ""))) return null;
  if (/\b\d+(?:\.\d+)?\s?(?:kg|lbs?|cm|in|bpm|mmhg|%)\b/i.test(t)) return null;
  if (!/^[\p{L}\p{N} .,'()+\-/&]+$/u.test(t)) return null;
  return t;
}

export function termKey(term: string): string {
  return term.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, " ").trim();
}

const enc = encodeURIComponent;
const q = (term: string) => `"${term.replace(/"/g, "")}"`;

export function pubmedSearchUrl(term: string, kind: "relevance" | "high_quality" | "animal_only", apiKey?: string): string {
  let query: string;
  let sort = "relevance";
  let retmax = 15;
  if (kind === "high_quality") {
    query = `${term} AND (meta-analysis[pt] OR systematic review[pt] OR randomized controlled trial[pt])`;
    sort = "pub_date";
    retmax = 10;
  } else if (kind === "animal_only") {
    query = `${term} AND animals[mh] NOT humans[mh]`;
    retmax = 30;
  } else {
    query = term;
  }
  return `${EUTILS}/esearch.fcgi?db=pubmed&retmode=json&retmax=${retmax}&sort=${sort}&term=${enc(query)}&tool=${TOOL}${apiKey ? `&api_key=${enc(apiKey)}` : ""}`;
}

export function pubmedSummaryUrl(ids: string[], apiKey?: string): string {
  return `${EUTILS}/esummary.fcgi?db=pubmed&retmode=json&id=${ids.map(enc).join(",")}&tool=${TOOL}${apiKey ? `&api_key=${enc(apiKey)}` : ""}`;
}

export const CTGOV_FIELDS = "NCTId,BriefTitle,OverallStatus,StudyType,Phase,DesignAllocation,StartDate,CompletionDate,LastUpdatePostDate,ResultsFirstPostDate,HasResults";

export function ctgovUrl(term: string, withFields = true): string {
  return `https://clinicaltrials.gov/api/v2/studies?format=json&query.intr=${enc(term)}&pageSize=10&sort=${enc("LastUpdatePostDate:desc")}` +
    (withFields ? `&fields=${enc(CTGOV_FIELDS)}` : "");
}

export function openFdaLabelUrl(term: string): string {
  const t = q(term);
  const search = `openfda.generic_name:${t} OR openfda.brand_name:${t} OR openfda.substance_name:${t}`;
  return `https://api.fda.gov/drug/label.json?search=${enc(search)}&limit=5`;
}

/** Cache key: the URL with any API key removed (the key must never be stored). */
export function cacheKey(url: string): string {
  return url.replace(/&api_key=[^&]*/g, "");
}

function yearOf(s: unknown): number | null {
  const m = typeof s === "string" ? s.match(/\b(19|20)\d{2}\b/) : null;
  return m ? Number(m[0]) : null;
}

export function parseEsearchIds(json: any): string[] {
  const ids = json?.esearchresult?.idlist;
  return Array.isArray(ids) ? ids.filter((x: unknown) => typeof x === "string" && /^\d{1,9}$/.test(x)) : [];
}

export function parsePubmedSummary(json: any, animalIds: Set<string>, retrievedAt: string): Citation[] {
  const result = json?.result ?? {};
  const uids: string[] = Array.isArray(result.uids) ? result.uids : [];
  const out: Citation[] = [];
  for (const uid of uids) {
    const r = result[uid];
    if (!r || typeof r !== "object" || r.error) continue;
    const title = String(r.title ?? "").replace(/<[^>]+>/g, "").trim().slice(0, 400);
    const pubtypes: string[] = Array.isArray(r.pubtype) ? r.pubtype.filter((x: unknown) => typeof x === "string") : [];
    out.push({
      source: "pubmed",
      id: String(uid),
      title,
      year: yearOf(r.pubdate) ?? yearOf(r.sortpubdate) ?? yearOf(r.epubdate),
      url: `https://pubmed.ncbi.nlm.nih.gov/${uid}/`,
      publication_types: pubtypes,
      study_kind: classifyPubmed(pubtypes, title, animalIds.has(String(uid))),
      retrieved_at: retrievedAt,
    });
  }
  return out;
}

export interface TrialInfo { nct: string; status: string; has_results: boolean; study_type: string; randomized: boolean; last_update: string | null }

export function parseCtgov(json: any, retrievedAt: string): { citations: Citation[]; trials: TrialInfo[] } {
  const studies = Array.isArray(json?.studies) ? json.studies : [];
  const citations: Citation[] = [];
  const trials: TrialInfo[] = [];
  for (const s of studies) {
    const p = s?.protocolSection ?? {};
    const nct = p.identificationModule?.nctId;
    if (typeof nct !== "string" || !/^NCT\d{8}$/.test(nct)) continue;
    const status = String(p.statusModule?.overallStatus ?? "UNKNOWN");
    const studyType = String(p.designModule?.studyType ?? "UNKNOWN");
    const phases: string[] = Array.isArray(p.designModule?.phases) ? p.designModule.phases : [];
    const allocation = String(p.designModule?.designInfo?.allocation ?? "");
    const hasResults = s?.hasResults === true;
    const randomized = allocation === "RANDOMIZED";
    const kind: StudyKind = hasResults && studyType === "INTERVENTIONAL" ? "trial_with_results" : "trial_registration";
    const date = p.statusModule?.completionDateStruct?.date ?? p.statusModule?.startDateStruct?.date;
    citations.push({
      source: "clinicaltrials",
      id: nct,
      title: String(p.identificationModule?.briefTitle ?? nct).slice(0, 400),
      year: yearOf(date),
      url: `https://clinicaltrials.gov/study/${nct}`,
      publication_types: [studyType, ...phases, allocation, status, hasResults ? "HAS_RESULTS" : "NO_RESULTS_POSTED"].filter(Boolean),
      study_kind: kind,
      retrieved_at: retrievedAt,
    });
    trials.push({ nct, status, has_results: hasResults, study_type: studyType, randomized, last_update: p.statusModule?.lastUpdatePostDateStruct?.date ?? null });
  }
  return { citations, trials };
}

export interface LabelInfo {
  set_id: string;
  title: string;
  effective_time: string | null;
  approved: boolean;              // has an NDA/ANDA/BLA application number
  application_numbers: string[];
  product_type: string | null;
  generic_names: string[];
  indications: string;
  contraindications: string;
  boxed_warning: string;
  warnings: string;
  interactions: string;
}

const firstText = (x: unknown, max: number) => (Array.isArray(x) ? x.filter((s) => typeof s === "string").join(" ") : "").replace(/\s+/g, " ").trim().slice(0, max);

export function parseOpenFdaLabel(json: any, retrievedAt: string): { citation: Citation; label: LabelInfo } | null {
  const results = Array.isArray(json?.results) ? json.results : [];
  if (!results.length) return null;
  const r = results.find((x: any) => Array.isArray(x?.openfda?.application_number) && x.openfda.application_number.length) ?? results[0];
  const setId = String(r.set_id ?? r.id ?? "");
  if (!setId) return null;
  const of = r.openfda ?? {};
  const brand = Array.isArray(of.brand_name) ? of.brand_name[0] : null;
  const generic = Array.isArray(of.generic_name) ? of.generic_name : [];
  const apps: string[] = Array.isArray(of.application_number) ? of.application_number : [];
  const productType = Array.isArray(of.product_type) ? of.product_type[0] : null;
  const name = brand && generic[0] ? `${brand} (${generic[0]})` : (brand ?? generic[0] ?? setId);
  const title = `FDA label: ${name}`;
  const label: LabelInfo = {
    set_id: setId,
    title,
    effective_time: typeof r.effective_time === "string" ? r.effective_time : null,
    approved: apps.some((a) => /^(NDA|ANDA|BLA)/i.test(a)),
    application_numbers: apps.slice(0, 5),
    product_type: productType,
    generic_names: generic.slice(0, 5),
    indications: firstText(r.indications_and_usage, 800),
    contraindications: firstText(r.contraindications, 1500),
    boxed_warning: firstText(r.boxed_warning, 1000),
    warnings: firstText(r.warnings_and_cautions ?? r.warnings, 3000),
    interactions: firstText(r.drug_interactions, 4000),
  };
  const citation: Citation = {
    source: "fda_label",
    id: setId,
    title,
    year: yearOf(label.effective_time?.slice(0, 4)),
    url: `https://dailymed.nlm.nih.gov/dailymed/lookup.cfm?setid=${enc(setId)}`,
    publication_types: [productType ?? "DRUG LABEL", ...apps.slice(0, 2)].filter(Boolean),
    study_kind: label.approved ? "regulatory_label" : "other",
    retrieved_at: retrievedAt,
  };
  return { citation, label };
}

export interface SourceStatus { source: "pubmed" | "clinicaltrials" | "fda_label"; ok: boolean; cached: boolean; fetched_at: string | null; note?: string }

export interface Evidence {
  term: string;
  citations: Citation[];
  trials: TrialInfo[];
  label: LabelInfo | null;
  sources: SourceStatus[];
  retrieved_at: string;           // oldest fetch time among sources used
}

export interface RetrieveDeps {
  fetch: FetchLike;
  cache: ResearchCache;
  now: () => Date;
  ncbiApiKey?: string;
  ttlMs?: number;
  timeoutMs?: number;
  onFetch?: (url: string) => void;  // observability hook for tests
}

class HttpError extends Error {
  status: number;
  constructor(status: number) { super(`http ${status}`); this.status = status; }
}

/** GET JSON via the shared cache. 404 from openFDA means "no results" and is cached as such. */
export async function cachedJson(url: string, source: string, query: string, deps: RetrieveDeps, allow404 = false): Promise<{ json: any; cached: boolean; fetched_at: string }> {
  const key = cacheKey(url);
  const now = deps.now();
  const hit = await deps.cache.get(key, deps.ttlMs ?? DEFAULT_TTL_MS, now);
  if (hit) return { json: hit.payload, cached: true, fetched_at: hit.fetched_at };
  deps.onFetch?.(url);
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), deps.timeoutMs ?? 15_000);
  let res: FetchResponse;
  try {
    res = await deps.fetch(url, { headers: { Accept: "application/json" }, signal: ctrl.signal });
  } finally {
    clearTimeout(timer);
  }
  let json: any;
  if (res.ok) json = await res.json();
  else if (allow404 && res.status === 404) json = { results: [] };
  else throw new HttpError(res.status);
  const fetchedAt = now.toISOString();
  await deps.cache.put(key, source, query, json, fetchedAt);
  return { json, cached: false, fetched_at: fetchedAt };
}

/** Retrieves PubMed, ClinicalTrials.gov and openFDA evidence for one term. Never throws for source errors. */
export async function retrieveEvidence(rawTerm: string, deps: RetrieveDeps, opts: { label?: boolean; trials?: boolean } = {}): Promise<Evidence> {
  const term = sanitizeTerm(rawTerm);
  if (!term) throw new Error("bad_term");
  const sources: SourceStatus[] = [];
  const citations: Citation[] = [];
  let trials: TrialInfo[] = [];
  let label: LabelInfo | null = null;
  const times: string[] = [];

  // PubMed: relevance + recent high-quality designs + MeSH animal-only tagging, then one summary call.
  try {
    const key = deps.ncbiApiKey;
    const rel = await cachedJson(pubmedSearchUrl(term, "relevance", key), "pubmed", term, deps);
    const hq = await cachedJson(pubmedSearchUrl(term, "high_quality", key), "pubmed", term, deps);
    const animal = await cachedJson(pubmedSearchUrl(term, "animal_only", key), "pubmed", term, deps);
    const ids = [...new Set([...parseEsearchIds(hq.json), ...parseEsearchIds(rel.json)])].slice(0, 25);
    let fetchedAt = [rel, hq, animal].map((x) => x.fetched_at).sort()[0];
    let cached = rel.cached && hq.cached && animal.cached;
    if (ids.length) {
      const sum = await cachedJson(pubmedSummaryUrl([...ids].sort(), key), "pubmed", term, deps);
      cached = cached && sum.cached;
      fetchedAt = [fetchedAt, sum.fetched_at].sort()[0];
      citations.push(...parsePubmedSummary(sum.json, new Set(parseEsearchIds(animal.json)), fetchedAt));
    }
    sources.push({ source: "pubmed", ok: true, cached, fetched_at: fetchedAt });
    times.push(fetchedAt);
  } catch (e) {
    sources.push({ source: "pubmed", ok: false, cached: false, fetched_at: null, note: (e as Error).message.slice(0, 60) });
  }

  if (opts.trials !== false) {
    try {
      let r;
      try {
        r = await cachedJson(ctgovUrl(term), "clinicaltrials", term, deps);
      } catch (e) {
        // If the field list is rejected (400), retry once with the full record.
        if (e instanceof HttpError && e.status === 400) r = await cachedJson(ctgovUrl(term, false), "clinicaltrials", term, deps);
        else throw e;
      }
      const parsed = parseCtgov(r.json, r.fetched_at);
      citations.push(...parsed.citations);
      trials = parsed.trials;
      sources.push({ source: "clinicaltrials", ok: true, cached: r.cached, fetched_at: r.fetched_at });
      times.push(r.fetched_at);
    } catch (e) {
      sources.push({ source: "clinicaltrials", ok: false, cached: false, fetched_at: null, note: (e as Error).message.slice(0, 60) });
    }
  }

  if (opts.label !== false) {
    try {
      const r = await cachedJson(openFdaLabelUrl(term), "fda_label", term, deps, true);
      const parsed = parseOpenFdaLabel(r.json, r.fetched_at);
      if (parsed) { citations.push(parsed.citation); label = parsed.label; }
      sources.push({ source: "fda_label", ok: true, cached: r.cached, fetched_at: r.fetched_at, note: parsed ? undefined : "no label found" });
      times.push(r.fetched_at);
    } catch (e) {
      sources.push({ source: "fda_label", ok: false, cached: false, fetched_at: null, note: (e as Error).message.slice(0, 60) });
    }
  }

  return { term, citations, trials, label, sources, retrieved_at: times.sort()[0] ?? deps.now().toISOString() };
}

/** Only the label (used for the user's current Rx/OTC compounds in the interaction cross-check). */
export async function retrieveLabel(rawTerm: string, deps: RetrieveDeps): Promise<LabelInfo | null> {
  const term = sanitizeTerm(rawTerm);
  if (!term) return null;
  try {
    const r = await cachedJson(openFdaLabelUrl(term), "fda_label", term, deps, true);
    return parseOpenFdaLabel(r.json, r.fetched_at)?.label ?? null;
  } catch {
    return null;
  }
}
