// Deterministic safety layer around the language model. The model is never the only safeguard.

// Kept in sync with VitalCore's UrgentSymptomScreen (Swift). Conservative: errs toward showing
// emergency guidance. Not clinically validated — see docs/RELEASE_READINESS.md.
const URGENT_PHRASES = [
  "chest pain", "chest pressure", "chest tightness", "can't breathe", "cannot breathe", "trouble breathing",
  "shortness of breath", "difficulty breathing", "face drooping", "slurred speech", "sudden weakness",
  "sudden numbness", "worst headache", "fainted", "passed out", "loss of consciousness", "seizure",
  "suicidal", "suicide", "kill myself", "end my life", "overdose", "throat swelling", "tongue swelling",
  "anaphylaxis", "coughing blood", "vomiting blood", "black stool", "severe bleeding",
];

export const URGENT_MESSAGE =
  "What you've described can be a sign of something serious. If it's happening now or feels like an emergency, " +
  "please call your local emergency number (911 in the US) or go to the nearest emergency department. " +
  "If you're thinking about harming yourself, call or text 988 (US) or your local crisis line. " +
  "I can't assess emergencies, but I'm here to talk once you're safe.";

export function screenUrgent(text: string): { urgent: boolean; matched: string[] } {
  const lower = text.toLowerCase().replace(/[’']/g, "'");
  const matched = URGENT_PHRASES.filter((p) => lower.includes(p));
  return { urgent: matched.length > 0, matched };
}

// Detects imperative dosing directives such as "increase to 200 mg", "take 5 mg daily",
// "inject 0.5 mL". Study-reported doses ("studies used 5 mg") are allowed by the policy, so
// the guard only appends a clinician notice; it does not delete content.
const DOSE_UNIT = String.raw`(?:mcg|µg|ug|mg|g|ml|iu|units?)`;
const DIRECTIVE = new RegExp(
  String.raw`\b(?:you should|i recommend|i'd recommend|try|start(?:ing)?|increase|decrease|reduce|raise|lower|bump|go up|go down|switch|take|inject|dose)\b[^.!?\n]{0,40}?\b\d+(?:[.,]\d+)?\s?${DOSE_UNIT}\b`,
  "i",
);

export const CLINICIAN_NOTICE =
  "Note: I can't recommend starting, stopping or changing doses of medications, hormones, peptides or other compounds. " +
  "Please make any dose decisions with your prescribing clinician.";

export interface SafetyClassification {
  urgent: boolean;
  needs_clinician: boolean;
  topics: string[];
}

const INVESTIGATIONAL_TOPICS = new Set(["peptide", "investigational", "compounded"]);

export function guardReply(reply: string, safety: SafetyClassification): { text: string; guardApplied: string[] } {
  const applied: string[] = [];
  let text = reply.trim();
  if (safety.urgent && !text.includes("emergency")) {
    text = `${URGENT_MESSAGE}\n\n${text}`;
    applied.push("urgent_prefix");
  }
  // For peptides, compounded and investigational compounds the guard is stricter: any sentence
  // carrying a dose, frequency or cycle instruction is removed, not just annotated.
  let removed = false;
  if (safety.topics.some((t) => INVESTIGATIONAL_TOPICS.has(t))) {
    const s = stripDosing(text);
    if (s.removed > 0) { text = s.text; removed = true; applied.push("dose_protocol_removed"); }
  }
  const hasDirective = DIRECTIVE.test(text);
  if ((hasDirective || removed || safety.needs_clinician) && !text.includes(CLINICIAN_NOTICE)) {
    text = `${text}\n\n${CLINICIAN_NOTICE}`;
    applied.push(hasDirective || removed ? "dose_directive_notice" : "clinician_notice");
  }
  return { text, guardApplied: applied };
}

// ---------------------------------------------------------------------------------------------
// Dosing-protocol stripper (strict). Used on every research output and on coach replies about
// peptides / investigational / compounded products. Removes whole sentences that contain an
// amount with a dose unit, a dose-per-weight expression, or a frequency/cycle instruction that is
// tied to taking, injecting or dosing something. Study-reported doses are removed too: research
// cards never carry doses.
// ---------------------------------------------------------------------------------------------
const AMOUNT_UNIT = /\b\d+(?:[.,]\d+)?\s?(?:-|–|to)?\s?(?:\d+(?:[.,]\d+)?\s?)?(?:mcg|µg|ug|mg|g|grams?|milligrams?|micrograms?|ml|cc|iu|units?|mg\/kg|mcg\/kg|µg\/kg|ug\/kg)\b/i;
const DOSE_WORDS = /\b(?:dos(?:e|es|ed|ing|age)|inject(?:ed|ing|ion|ions)?|administer(?:ed|ing)?|subcutaneous(?:ly)?|sub-?q|intramuscular(?:ly)?|reconstitut\w*|vial|syringe|pin(?:ning)?)\b/i;
const FREQ_CYCLE = /\b(?:once|twice|three times|\d+\s?(?:x|times))\s?(?:a|per|\/)\s?(?:day|week|month)\b|\b(?:daily|nightly|weekly|bid|tid|qid|qd|eod|every (?:other )?(?:day|morning|night|\d+ (?:hours|days)))\b|\b\d+\s?(?:weeks?|days?)\s?on\b|\b(?:on|off)[- ]cycle\b|\bcycl(?:e|es|ing)\b|\bstack(?:ing)?\b|\bprotocol\b|\bloading (?:dose|phase)\b|\btitrat\w*\b|\btaper\w*\b/i;
const EXPLICIT_PROTOCOL = /\b(?:dosing (?:protocol|schedule|regimen|guide)|dosage|per kg|per kilogram|body ?weight dose)\b/i;

export const DOSING_REFERRAL =
  "Dosing information is intentionally not provided. Dose, frequency and duration decisions for any compound — " +
  "especially investigational peptides — need a licensed clinician who knows your history and current medications.";

/**
 * True when a sentence carries dosing. `compoundTerms` (names of the drug/supplement being
 * discussed) widen the check: "take BPC-157 twice daily" has no amount but is still a protocol.
 */
export function containsDosing(sentence: string, compoundTerms: string[] = []): boolean {
  if (AMOUNT_UNIT.test(sentence) || EXPLICIT_PROTOCOL.test(sentence)) return true;
  if (!FREQ_CYCLE.test(sentence)) return false;
  if (DOSE_WORDS.test(sentence)) return true;
  const lower = sentence.toLowerCase();
  return compoundTerms.some((t) => t.length >= 3 && lower.includes(t.toLowerCase()));
}

/** Removes sentences that carry dosing; returns the cleaned text and how many were removed. */
export function stripDosing(text: string, compoundTerms: string[] = []): { text: string; removed: number } {
  let removed = 0;
  const lines = text.split(/\n/).map((line) => {
    const parts = line.split(/(?<=[.!?;])\s+/);
    const kept = parts.filter((p) => {
      if (containsDosing(p, compoundTerms)) { removed++; return false; }
      return true;
    });
    return kept.join(" ");
  });
  const cleaned = lines.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  return { text: cleaned, removed };
}

// ---------------------------------------------------------------------------------------------
// Red-flag triage for musculoskeletal and general complaints. Runs before any compound
// discussion. Deterministic, conservative and NOT clinically validated (see
// docs/RELEASE_READINESS.md); it errs toward recommending in-person evaluation.
// ---------------------------------------------------------------------------------------------
export type TriageLevel = "none" | "see_clinician" | "urgent" | "emergency";

interface RedFlag { id: string; label: string; level: Exclude<TriageLevel, "none">; pattern: RegExp; needsInjury?: boolean; injuryLevel?: Exclude<TriageLevel, "none"> }

const RED_FLAGS: RedFlag[] = [
  { id: "major_trauma", label: "a major injury or deformity", level: "emergency",
    pattern: /\b(?:car|motorcycle|bike|ski) (?:crash|accident)|\bhit by a (?:car|vehicle)\b|\bfell (?:from|off) (?:a |the )?(?:height|ladder|roof)|\bmajor trauma\b|\bdeform(?:ed|ity)\b|\bbone (?:is )?(?:sticking|poking) out\b|\bopen fracture\b/ },
  { id: "cauda_equina", label: "numbness in the groin/saddle area or loss of bladder or bowel control", level: "emergency",
    pattern: /\b(?:saddle|groin|genital) (?:area )?numb|\b(?:lost|loss of|losing) (?:bladder|bowel) control\b|\bincontinen\w*/ },
  { id: "cant_bear_weight", label: "being unable to bear weight or walk", level: "urgent",
    pattern: /\bcan't (?:bear|put|take|stand) (?:any |much )?weight\b|\bcan't (?:walk|stand)\b|\bnon[- ]?weight[- ]?bearing\b|\bcan't put (?:my )?(?:foot|leg) down\b/ },
  { id: "hot_swollen_joint", label: "a hot, red or swollen joint, or fever", level: "urgent",
    pattern: /\b(?:hot|warm|red)(?:,)? (?:and )?swollen\b|\bswollen(?:,)? (?:and )?(?:hot|warm|red)\b|\bfever\w*\b|\bchills\b/ },
  { id: "pop_and_swelling", label: "a 'pop' at the time of injury or rapid swelling", level: "urgent",
    pattern: /\b(?:heard|felt) a (?:loud )?pop\b|\bpopping sound\b|\b(?:swelled|swelling) (?:up )?(?:right away|immediately|quickly|rapidly)\b|\b(?:rapid|sudden) swelling\b/ },
  { id: "locking_giving_way", label: "locking, catching or giving way of the joint", level: "see_clinician", injuryLevel: "urgent", needsInjury: true,
    pattern: /\blocking\b|\blocks up\b|\blocked up\b|\b(?:knee|joint|it) (?:keeps )?lock(?:s|ed|ing)?\b|\bgets stuck\b|\bcatching\b|\bgiv(?:es|ing) (?:out|way)\b|\bgave (?:out|way)\b|\bbuckl(?:es|ing|ed)\b/ },
  { id: "numbness_weakness", label: "numbness, tingling or weakness", level: "urgent",
    pattern: /\bnumb(?:ness)?\b|\btingl(?:ing|y|es)\b|\bpins and needles\b|\bfoot drop\b|\b(?:leg|arm|foot|hand) (?:is |feels |went )?weak\b|\bweakness\b/ },
  { id: "dvt_signs", label: "a swollen, painful calf", level: "urgent",
    pattern: /\b(?:calf|lower leg) (?:is )?(?:swollen|swelling|tender and swollen)\b|\bswollen calf\b/ },
  { id: "severe_pain", label: "severe or rapidly worsening pain", level: "urgent",
    pattern: /\b(?:severe|unbearable|excruciating|worst ever) pain\b|\bpain (?:is )?(?:unbearable|excruciating)\b|\b(?:10|ten) (?:out of|\/) ?(?:10|ten)\b|\brapidly worsening\b/ },
  { id: "systemic_signs", label: "night pain, unexplained weight loss or a history of cancer", level: "see_clinician",
    pattern: /\bnight pain\b|\bpain (?:that )?wakes me\b|\bwakes me up at night\b|\bunexplained weight loss\b|\bhistory of cancer\b/ },
];

const INJURY = /\b(?:injur\w*|fell|fall|fallen|twist\w*|pop\w*|accident|tackl\w*|sprain\w*|collision|landed (?:on|awkwardly)|hit)\b/;
const NEGATION = /\b(?:no|not|without|never|denies|don't have|haven't had|didn't have|isn't|wasn't|any)\s+(?:\w+\s+){0,2}$/;
const LEVEL_RANK: Record<TriageLevel, number> = { none: 0, see_clinician: 1, urgent: 2, emergency: 3 };

export interface TriageResult {
  level: TriageLevel;
  stop: boolean; // true → do not discuss compounds; show the triage message only
  flags: { id: string; label: string; level: TriageLevel }[];
  message: string;
}

export function normalizeComplaint(text: string): string {
  return text.toLowerCase().replace(/[’‘`]/g, "'")
    .replace(/\bcannot\b|\bcan not\b|\bunable to\b|\bnot able to\b|\bcant\b/g, "can't");
}

function negated(text: string, index: number): boolean {
  return NEGATION.test(text.slice(Math.max(0, index - 30), index));
}

export function triageMessage(level: TriageLevel, labels: string[]): string {
  const what = labels.length ? labels.join("; ") : "what you described";
  switch (level) {
    case "emergency":
      return `${URGENT_MESSAGE}\n\nYou mentioned ${what}. Please get emergency care first — supplements, peptides and other compounds are not a substitute.`;
    case "urgent":
      return `You mentioned ${what}. Together with pain, this can be a sign of an injury or condition that needs an in-person examination soon ` +
        "(for example a fracture, a ligament or cartilage tear, a nerve problem, a clot or a joint infection). " +
        "Please get assessed today — urgent care, an emergency department, or your clinician — and avoid loading the area until then. " +
        "I'm not going to discuss compounds or supplements for this until you've been checked, because they could delay the care you need. " +
        "If symptoms are severe or getting worse quickly, call your local emergency number.";
    case "see_clinician":
      return `You mentioned ${what}. That's worth a check-up with a clinician (within the next few days) so the cause can be properly identified. ` +
        "General information below is educational only and is not a substitute for that evaluation.";
    default:
      return "";
  }
}

/** Screens free text for emergency and musculoskeletal/general red flags. */
export function screenRedFlags(text: string): TriageResult {
  const t = normalizeComplaint(text ?? "");
  const flags: TriageResult["flags"] = [];
  const urgent = screenUrgent(t);
  if (urgent.urgent) flags.push({ id: "emergency_symptom", label: urgent.matched.join(", "), level: "emergency" });
  const injury = INJURY.test(t);
  for (const f of RED_FLAGS) {
    const re = new RegExp(f.pattern.source, "g");
    let m: RegExpExecArray | null;
    let hit = false;
    while ((m = re.exec(t)) !== null) {
      if (!negated(t, m.index)) { hit = true; break; }
    }
    if (!hit) continue;
    const level = f.needsInjury && injury ? (f.injuryLevel ?? f.level) : f.level;
    flags.push({ id: f.id, label: f.label, level });
  }
  const level = flags.reduce<TriageLevel>((acc, f) => (LEVEL_RANK[f.level] > LEVEL_RANK[acc] ? f.level : acc), "none");
  return {
    level,
    stop: level === "urgent" || level === "emergency",
    flags,
    message: triageMessage(level, flags.map((f) => f.label)),
  };
}

/** Merges two triage results, keeping the most serious level. */
export function mergeTriage(a: TriageResult, b: TriageResult): TriageResult {
  const flags = [...a.flags, ...b.flags.filter((f) => !a.flags.some((x) => x.id === f.id))];
  const level = flags.reduce<TriageLevel>((acc, f) => (LEVEL_RANK[f.level] > LEVEL_RANK[acc] ? f.level : acc), "none");
  return { level, stop: level === "urgent" || level === "emergency", flags, message: triageMessage(level, flags.map((f) => f.label)) };
}

export function hasDoseDirective(text: string): boolean {
  return DIRECTIVE.test(text);
}

/** Strips characters that could be used to break out of the data block in the prompt. */
export function sanitizeUserText(text: string, maxLength: number): string {
  return text.replace(/\u0000/g, "").slice(0, maxLength).trim();
}
