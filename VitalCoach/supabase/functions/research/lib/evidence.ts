// Evidence levels, per-citation study classification and the deterministic evidence cap.
// The language model may *claim* a level; the server caps it to what the verified citations
// actually support. Pure functions only (unit-tested in research.test.ts).

export const EVIDENCE_LEVELS = [
  "established_human",
  "moderate_human",
  "preliminary_human",
  "preclinical_animal",
  "in_vitro_mechanistic",
  "anecdotal_community",
  "insufficient",
] as const;
export type EvidenceLevel = typeof EVIDENCE_LEVELS[number];

/** Higher = stronger. */
export function levelRank(l: EvidenceLevel): number {
  return EVIDENCE_LEVELS.length - 1 - EVIDENCE_LEVELS.indexOf(l);
}

export function isEvidenceLevel(x: unknown): x is EvidenceLevel {
  return typeof x === "string" && (EVIDENCE_LEVELS as readonly string[]).includes(x);
}

export const LEVEL_INFO: Record<EvidenceLevel, { label: string; explanation: string }> = {
  established_human: {
    label: "Established human evidence",
    explanation: "Supported by systematic reviews/meta-analyses or several randomized controlled trials in people (or an FDA approval for a labeled use). Results are fairly consistent, but individual responses still vary.",
  },
  moderate_human: {
    label: "Moderate human evidence",
    explanation: "At least one randomized controlled trial in people supports it, but the evidence is limited in size, duration or consistency. Future studies could change the picture.",
  },
  preliminary_human: {
    label: "Preliminary human evidence",
    explanation: "Only small, uncontrolled or observational human studies, case reports or unpublished trial results. These can suggest an effect but cannot show that it works.",
  },
  preclinical_animal: {
    label: "Animal studies only",
    explanation: "Findings come from animal studies. Many results in animals do not translate to people, and safe or effective human use is unknown.",
  },
  in_vitro_mechanistic: {
    label: "Lab/mechanism studies only",
    explanation: "Findings come from cells or test tubes. They show a possible mechanism, not an effect in a living person.",
  },
  anecdotal_community: {
    label: "Anecdotal reports only (unverified)",
    explanation: "Based on personal stories, forums or marketing — not studies. These reports are unverified and subject to strong biases.",
  },
  insufficient: {
    label: "Insufficient evidence",
    explanation: "We could not find enough reliable evidence to say whether it works or is safe. Missing evidence is not evidence of safety.",
  },
};

export type CitationSource = "pubmed" | "clinicaltrials" | "fda_label";

export type StudyKind =
  | "meta_analysis" | "systematic_review" | "rct" | "clinical_trial" | "observational" | "case_report"
  | "guideline" | "review" | "animal" | "in_vitro" | "trial_registration" | "trial_with_results"
  | "regulatory_label" | "other";

export interface Citation {
  source: CitationSource;
  id: string;                   // PMID, NCT number or openFDA set_id
  title: string;
  year: number | null;
  url: string;
  publication_types: string[];  // PubMed pubtype array; trial design/status for ClinicalTrials.gov; label type for FDA
  study_kind: StudyKind;
  retrieved_at: string;         // ISO time the source was fetched (cache time)
}

const ANIMAL_TITLE = /\b(?:rats?|mice|mouse|murine|rodents?|rabbits?|canine|dogs?|porcine|pigs?|swine|sheep|ovine|equine|horses?|bovine|primates?|monkeys?|zebrafish|animal models?|in vivo (?:model|study))\b|\bpreclinical\b/i;
const IN_VITRO_TITLE = /\bin vitro\b|\bcell (?:line|culture)s?\b|\bcultured\b|\bfibroblasts?\b|\bkeratinocytes?\b|\bendothelial cells?\b|\bmyoblasts?\b|\btenocytes?\b|\bchondrocytes?\b|\bex vivo\b/i;
const HUMAN_TITLE = /\b(?:patients?|participants?|adults?|men|women|humans?|volunteers?|athletes?|children|subjects)\b/i;

const has = (types: string[], ...names: string[]) => types.some((t) => names.some((n) => t.toLowerCase() === n.toLowerCase()));

/**
 * Classifies one PubMed record from its publication types, title and whether the MeSH-filtered
 * "animals NOT humans" search returned it. Animal/in-vitro signals win over design pubtypes,
 * because PubMed tags e.g. veterinary RCTs and systematic reviews of rodent studies with the
 * same design pubtypes as human studies.
 */
export function classifyPubmed(pubtypes: string[], title: string, animalOnly: boolean): StudyKind {
  const animalTitle = ANIMAL_TITLE.test(title) && !HUMAN_TITLE.test(title);
  const inVitroTitle = IN_VITRO_TITLE.test(title) && !HUMAN_TITLE.test(title);
  if (inVitroTitle && !ANIMAL_TITLE.test(title)) return "in_vitro";
  if (animalOnly || animalTitle) return "animal";
  if (has(pubtypes, "Meta-Analysis")) return "meta_analysis";
  if (has(pubtypes, "Systematic Review")) return "systematic_review";
  if (has(pubtypes, "Randomized Controlled Trial", "Equivalence Trial", "Pragmatic Clinical Trial")) return "rct";
  if (pubtypes.some((t) => /^clinical trial/i.test(t)) || has(pubtypes, "Controlled Clinical Trial", "Clinical Study")) return "clinical_trial";
  if (has(pubtypes, "Observational Study", "Comparative Study", "Multicenter Study", "Twin Study", "Validation Study", "Evaluation Study")) return "observational";
  if (has(pubtypes, "Case Reports")) return "case_report";
  if (has(pubtypes, "Practice Guideline", "Guideline", "Consensus Development Conference")) return "guideline";
  if (has(pubtypes, "Review", "Scoping Review", "Narrative Review")) return "review";
  if (inVitroTitle) return "in_vitro";
  return "other";
}

export interface SupportedLevel { level: EvidenceLevel; basis: string }

/** The strongest level the given (verified) citations can support. */
export function supportedLevel(citations: Citation[]): SupportedLevel {
  const n = (k: StudyKind) => citations.filter((c) => c.study_kind === k).length;
  const syn = n("meta_analysis") + n("systematic_review");
  if (syn >= 1) return { level: "established_human", basis: `${syn} systematic review/meta-analysis` };
  if (n("rct") >= 2) return { level: "established_human", basis: `${n("rct")} randomized controlled trials` };
  if (n("regulatory_label") >= 1) return { level: "established_human", basis: "an FDA-approved label (for its labeled uses only)" };
  if (n("rct") === 1) return { level: "moderate_human", basis: "1 randomized controlled trial" };
  if (n("guideline") >= 1) return { level: "moderate_human", basis: "a clinical practice guideline" };
  const prelim = n("clinical_trial") + n("observational") + n("case_report") + n("trial_with_results");
  if (prelim >= 1) return { level: "preliminary_human", basis: `${prelim} non-randomized/observational human stud${prelim === 1 ? "y" : "ies"} or posted trial results` };
  if (n("animal") >= 1) return { level: "preclinical_animal", basis: `${n("animal")} animal stud${n("animal") === 1 ? "y" : "ies"}` };
  if (n("in_vitro") >= 1) return { level: "in_vitro_mechanistic", basis: `${n("in_vitro")} laboratory stud${n("in_vitro") === 1 ? "y" : "ies"}` };
  return { level: "insufficient", basis: citations.length ? "no human, animal or lab study among the cited sources" : "no verified citations" };
}

export interface EvidenceAssessment {
  level: EvidenceLevel;
  claimed_level: EvidenceLevel | null;
  label: string;
  explanation: string;          // plain-language meaning of the level
  model_explanation: string;    // model's own explanation, after guards
  capped: boolean;
  cap_reason: string | null;
  supported_by: string;
}

/**
 * Caps a model-claimed level to what verified citations support. Anecdotal is the only level
 * allowed without citations (it is, by definition, not backed by studies).
 */
export function capEvidence(claimed: unknown, cited: Citation[], opts: { hasAnecdotes?: boolean; modelExplanation?: string } = {}): EvidenceAssessment {
  const sup = supportedLevel(cited);
  const claim: EvidenceLevel | null = isEvidenceLevel(claimed) ? claimed : null;
  let level: EvidenceLevel;
  let capped = false;
  let reason: string | null = null;
  if (!claim) {
    level = "insufficient";
    capped = claimed != null;
    reason = capped ? "The model returned an unrecognized evidence level." : null;
  } else if (claim === "anecdotal_community" || claim === "insufficient") {
    level = claim;
  } else if (levelRank(claim) > levelRank(sup.level)) {
    level = sup.level === "insufficient" && opts.hasAnecdotes ? "anecdotal_community" : sup.level;
    capped = true;
    reason = `Claimed "${LEVEL_INFO[claim].label}", but the verified citations support at most "${LEVEL_INFO[sup.level].label}" (${sup.basis}).`;
  } else {
    level = claim;
  }
  return {
    level, claimed_level: claim, label: LEVEL_INFO[level].label, explanation: LEVEL_INFO[level].explanation,
    model_explanation: opts.modelExplanation ?? "", capped, cap_reason: reason, supported_by: sup.basis,
  };
}

/** Keeps only citations whose IDs are in the retrieved set; reports dropped (invented) IDs. */
export function verifyCitations(citedIds: unknown, retrieved: Citation[]): { citations: Citation[]; dropped: string[] } {
  const byId = new Map(retrieved.map((c) => [normalizeId(c.id), c]));
  const out: Citation[] = [];
  const dropped: string[] = [];
  const seen = new Set<string>();
  for (const raw of Array.isArray(citedIds) ? citedIds : []) {
    if (typeof raw !== "string") continue;
    const key = normalizeId(raw);
    const c = byId.get(key);
    if (!c) { dropped.push(raw.slice(0, 40)); continue; }
    if (!seen.has(key)) { seen.add(key); out.push(c); }
  }
  return { citations: out, dropped };
}

/** "PMID: 123", "pmid123", "123" → "123"; NCT and set IDs are upper/lower-cased consistently. */
export function normalizeId(id: string): string {
  return id.trim().replace(/^pmid[:\s]*/i, "").toLowerCase();
}

// Anecdotal reports are always labeled unverified, with the biases that make them unreliable.
export const ANECDOTE_BIASES: { name: string; explanation: string }[] = [
  { name: "Placebo effect", explanation: "Expecting a benefit can make people feel better regardless of what they took, especially for pain, energy and mood." },
  { name: "Selection and reporting bias", explanation: "People with good experiences post more often; those who felt nothing or had problems often stay silent." },
  { name: "Survivorship bias", explanation: "Stories come from people still using the product; people who quit because of side effects or no effect drop out of the conversation." },
  { name: "Product contamination and purity", explanation: "Unregulated products (e.g. research-chemical peptides, some supplements) may contain the wrong dose, other substances, or contaminants; one person's product may differ from another's." },
  { name: "Conflicts of interest", explanation: "Sellers, affiliates, clinics and influencers may profit from positive reports." },
  { name: "Natural recovery and co-interventions", explanation: "Many problems (like overuse pain) improve on their own or because of rest, training changes or other treatments started at the same time." },
];

export interface AnecdotalBlock { summary: string; verified: false; label: string; biases: { name: string; explanation: string }[] }

export function anecdotalBlock(summary: string): AnecdotalBlock {
  const s = summary.trim();
  return {
    summary: s || "No anecdotal reports summarized.",
    verified: false,
    label: "Unverified anecdotal reports — not evidence of effectiveness or safety",
    biases: ANECDOTE_BIASES,
  };
}
