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

export function guardReply(reply: string, safety: SafetyClassification): { text: string; guardApplied: string[] } {
  const applied: string[] = [];
  let text = reply.trim();
  if (safety.urgent && !text.includes("emergency")) {
    text = `${URGENT_MESSAGE}\n\n${text}`;
    applied.push("urgent_prefix");
  }
  const hasDirective = DIRECTIVE.test(text);
  if ((hasDirective || safety.needs_clinician) && !text.includes(CLINICIAN_NOTICE)) {
    text = `${text}\n\n${CLINICIAN_NOTICE}`;
    applied.push(hasDirective ? "dose_directive_notice" : "clinician_notice");
  }
  return { text, guardApplied: applied };
}

export function hasDoseDirective(text: string): boolean {
  return DIRECTIVE.test(text);
}

/** Strips characters that could be used to break out of the data block in the prompt. */
export function sanitizeUserText(text: string, maxLength: number): string {
  return text.replace(/\u0000/g, "").slice(0, maxLength).trim();
}
