// Deterministic candidate interventions for proactive discovery, and the established first-line
// approaches each complaint is compared against. Curated and conservative: candidates are only
// *topics to research*; their evidence level always comes from retrieved citations.
import type { CoachContext } from "../../coach/lib/context.ts";

export type CandidateKind = "non_drug" | "otc" | "prescription" | "supplement" | "clinician" | "followed_interest";

export interface Candidate {
  id: string;
  name: string;
  category: string;          // prompt.ts CATEGORIES
  kind: CandidateKind;
  search_term: string;       // the ONLY text sent to external research APIs
  reason_tags: string[];     // which goal/complaint produced it
}

const C = (id: string, name: string, category: string, kind: CandidateKind, search_term: string): Omit<Candidate, "reason_tags"> =>
  ({ id, name, category, kind, search_term });

const BY_COMPLAINT: Record<string, Omit<Candidate, "reason_tags">[]> = {
  knee: [
    C("knee_exercise_therapy", "Exercise therapy / physical therapy for knee pain", "exercise_rehab", "non_drug", "exercise therapy knee pain"),
    C("knee_weight_management", "Weight management for knee pain", "lifestyle", "non_drug", "weight loss knee osteoarthritis pain"),
    C("knee_topical_nsaid", "Topical NSAIDs (e.g. diclofenac gel)", "otc", "otc", "topical diclofenac knee"),
    C("knee_running_load", "Running load management and gait retraining", "exercise_rehab", "non_drug", "patellofemoral pain runners exercise"),
  ],
  back: [
    C("back_exercise", "Exercise therapy for low back pain", "exercise_rehab", "non_drug", "exercise therapy low back pain"),
    C("back_heat", "Superficial heat for low back pain", "lifestyle", "non_drug", "heat therapy low back pain"),
  ],
  shoulder: [C("shoulder_exercise", "Exercise therapy for shoulder pain", "exercise_rehab", "non_drug", "exercise therapy shoulder pain")],
  hip: [C("hip_exercise", "Exercise therapy for hip pain", "exercise_rehab", "non_drug", "exercise therapy hip osteoarthritis")],
  neck: [C("neck_exercise", "Exercise therapy for neck pain", "exercise_rehab", "non_drug", "exercise therapy neck pain")],
  ankle: [C("ankle_rehab", "Balance and strength rehab for ankle", "exercise_rehab", "non_drug", "ankle sprain exercise rehabilitation")],
  elbow: [C("elbow_loading", "Progressive loading for elbow tendinopathy", "exercise_rehab", "non_drug", "lateral epicondylitis exercise")],
};

const BY_GOAL: Record<string, Omit<Candidate, "reason_tags">[]> = {
  reduced_pain: [C("pain_exercise", "Exercise therapy for chronic pain", "exercise_rehab", "non_drug", "exercise therapy chronic pain")],
  fat_loss: [
    C("fatloss_resistance", "Resistance training during weight loss", "exercise_rehab", "non_drug", "resistance training body composition weight loss"),
    C("fatloss_protein", "Higher-protein diet for body composition", "nutrition", "non_drug", "high protein diet body composition"),
    C("fatloss_glp1", "GLP-1 receptor agonists (prescription)", "prescription", "prescription", "semaglutide weight loss"),
  ],
  muscle_mass: [
    C("muscle_resistance", "Progressive resistance training", "exercise_rehab", "non_drug", "resistance training muscle hypertrophy"),
    C("muscle_creatine", "Creatine monohydrate", "supplement", "supplement", "creatine supplementation"),
    C("muscle_protein", "Protein intake for muscle gain", "nutrition", "non_drug", "protein supplementation resistance training"),
  ],
  strength: [
    C("strength_resistance", "Progressive resistance training", "exercise_rehab", "non_drug", "resistance training muscle strength"),
    C("strength_creatine", "Creatine monohydrate", "supplement", "supplement", "creatine supplementation"),
  ],
  mobility: [C("mobility_stretching", "Stretching and mobility training", "exercise_rehab", "non_drug", "stretching range of motion")],
  cognitive_performance: [
    C("cog_sleep", "Sleep duration and regularity", "lifestyle", "non_drug", "sleep cognitive performance"),
    C("cog_aerobic", "Aerobic exercise for cognition", "exercise_rehab", "non_drug", "aerobic exercise cognitive function"),
  ],
  energy: [C("energy_sleep", "Sleep hygiene / CBT for insomnia", "lifestyle", "non_drug", "cognitive behavioral therapy insomnia")],
  longevity: [
    C("longevity_aerobic", "Cardiorespiratory fitness training", "exercise_rehab", "non_drug", "cardiorespiratory fitness mortality"),
    C("longevity_resistance", "Resistance training and mortality", "exercise_rehab", "non_drug", "muscle strengthening activity mortality"),
  ],
  recovery: [
    C("recovery_sleep", "Sleep extension for recovery", "lifestyle", "non_drug", "sleep extension athletes"),
    C("recovery_protein", "Post-exercise protein", "nutrition", "non_drug", "protein muscle recovery"),
  ],
};

const COMPLAINT_WORDS: [string, RegExp][] = [
  ["knee", /\bknees?\b|\bpatell|\bacl\b|\bmeniscus\b/i],
  ["back", /\b(?:low(?:er)? )?back\b|\blumbar\b|\bspine\b/i],
  ["shoulder", /\bshoulders?\b|\brotator cuff\b/i],
  ["hip", /\bhips?\b/i],
  ["neck", /\bneck\b/i],
  ["ankle", /\bankles?\b|\bachilles\b/i],
  ["elbow", /\belbows?\b|\btennis elbow\b/i],
];

/** Body-area complaints from free text, pain logs and the profile's injuries. */
export function detectComplaints(ctx: CoachContext | null, text = ""): string[] {
  const sources = [text, ...(ctx?.pain_last_14_days ?? []).map((p) => String(p.location ?? "")),
    ...((ctx?.profile?.injuries as unknown[] | undefined) ?? []).map(String)];
  const found = new Set<string>();
  for (const s of sources) for (const [k, re] of COMPLAINT_WORDS) if (re.test(s)) found.add(k);
  return [...found];
}

/**
 * Up to `max` candidates from complaints, goals and research interests; at least half are
 * non-drug whenever any non-drug candidate exists.
 */
export function buildCandidates(ctx: CoachContext, interests: { term: string; display_name?: string | null }[], max = 6, text = ""): Candidate[] {
  const map = new Map<string, Candidate>();
  const push = (c: Omit<Candidate, "reason_tags">, tag: string) => {
    const e = map.get(c.search_term);
    if (e) { if (!e.reason_tags.includes(tag)) e.reason_tags.push(tag); return; }
    map.set(c.search_term, { ...c, reason_tags: [tag] });
  };
  for (const k of detectComplaints(ctx, text)) for (const c of BY_COMPLAINT[k] ?? []) push(c, `${k} pain`);
  for (const g of ctx.goals) for (const c of BY_GOAL[g] ?? []) push(c, `goal: ${g}`);
  for (const i of interests.slice(0, 5)) {
    push({ id: `interest_${i.term.toLowerCase().replace(/[^a-z0-9]+/g, "_").slice(0, 40)}`, name: i.display_name || i.term, category: "other", kind: "followed_interest", search_term: i.term }, "your research interest");
  }
  const all = [...map.values()];
  const nonDrug = all.filter((c) => c.kind === "non_drug");
  const other = all.filter((c) => c.kind !== "non_drug");
  const minNonDrug = Math.min(nonDrug.length, Math.ceil(max / 2));
  const picked = [...nonDrug.slice(0, minNonDrug)];
  for (const c of [...other, ...nonDrug.slice(minNonDrug)]) { if (picked.length >= max) break; picked.push(c); }
  return picked.slice(0, max);
}

export interface EstablishedApproach { name: string; kind: CandidateKind; note: string }

const ESTABLISHED: Record<string, EstablishedApproach[]> = {
  knee: [
    { name: "Exercise therapy / physical therapy", kind: "non_drug", note: "Strengthening (quadriceps, hips) and graded return to running are first-line in clinical guidelines for most non-traumatic knee pain." },
    { name: "Weight management", kind: "non_drug", note: "When relevant, reducing body weight lowers knee joint load; guidelines recommend it for knee osteoarthritis." },
    { name: "Training-load changes", kind: "non_drug", note: "Temporarily reducing running volume or intensity, then building back gradually." },
    { name: "OTC pain relievers used per their label", kind: "otc", note: "Topical NSAIDs, oral NSAIDs or acetaminophen, following the label and checking interactions (e.g. NSAIDs with blood-pressure medicines)." },
    { name: "Clinician evaluation", kind: "clinician", note: "A clinician or physical therapist can identify the cause (e.g. patellofemoral pain, meniscus or ligament injury) and tailor treatment." },
  ],
  back: [
    { name: "Staying active and exercise therapy", kind: "non_drug", note: "Recommended first-line for most low back pain." },
    { name: "Heat", kind: "non_drug", note: "Superficial heat can ease acute low back pain." },
    { name: "OTC pain relievers used per their label", kind: "otc", note: "NSAIDs per label, checking interactions and conditions." },
    { name: "Clinician evaluation", kind: "clinician", note: "Especially if pain persists beyond a few weeks or there are nerve symptoms." },
  ],
};
const GENERIC_ESTABLISHED: EstablishedApproach[] = [
  { name: "Exercise therapy / physical therapy", kind: "non_drug", note: "Supervised, progressive exercise is a first-line approach for most musculoskeletal pain." },
  { name: "OTC pain relievers used per their label", kind: "otc", note: "Follow the label and check interactions with your current medicines." },
  { name: "Clinician evaluation", kind: "clinician", note: "To identify the cause and the right treatment." },
];

export function establishedApproaches(complaints: string[]): EstablishedApproach[] {
  if (!complaints.length) return [];
  for (const c of complaints) if (ESTABLISHED[c]) return ESTABLISHED[c];
  return GENERIC_ESTABLISHED;
}
