// Deterministic contraindication / interaction cross-check against the user's current compounds,
// conditions and allergies. Sources, in order of authority:
//   1. FDA label text (openFDA) of the compound being researched and of the user's Rx/OTC compounds.
//   2. A small curated rule table of well-known class interactions (documented, conservative).
//   3. A "no data" flag for compounds without a label — missing data is never reported as safe.
// This is NOT a complete interaction checker; every flag tells the user to confirm with a pharmacist.
import type { LabelInfo } from "./sources.ts";

export interface UserCompound { name: string; category: string }
export interface MedContext { compounds: UserCompound[]; conditions: string[]; allergies: string[] }

export interface InteractionFlag {
  with: string;                  // the user's compound, condition or allergy
  kind: "drug_interaction" | "condition" | "allergy" | "no_data";
  severity: "avoid_unless_clinician_approves" | "caution" | "unknown";
  detail: string;
  source: string;                // "fda_label:<set_id>" | "curated_rule" | "no_data"
}

// Common drug names → class terms used in label text and curated rules.
const CLASSES: Record<string, string[]> = {
  "ace_inhibitor": ["lisinopril", "enalapril", "ramipril", "benazepril", "captopril", "quinapril", "fosinopril", "perindopril", "trandolapril", "moexipril"],
  "arb": ["losartan", "valsartan", "irbesartan", "olmesartan", "telmisartan", "candesartan", "azilsartan"],
  "thiazide": ["hydrochlorothiazide", "chlorthalidone", "indapamide", "metolazone"],
  "loop_diuretic": ["furosemide", "bumetanide", "torsemide"],
  "potassium_sparing": ["spironolactone", "eplerenone", "amiloride", "triamterene"],
  "nsaid": ["ibuprofen", "naproxen", "diclofenac", "celecoxib", "meloxicam", "aspirin", "ketorolac", "indomethacin", "etodolac", "nabumetone", "advil", "motrin", "aleve", "voltaren"],
  "anticoagulant": ["warfarin", "apixaban", "rivaroxaban", "dabigatran", "edoxaban", "heparin", "enoxaparin", "eliquis", "xarelto"],
  "antiplatelet": ["clopidogrel", "prasugrel", "ticagrelor"],
  "ssri_snri": ["sertraline", "fluoxetine", "escitalopram", "citalopram", "paroxetine", "venlafaxine", "duloxetine", "desvenlafaxine"],
  "glp1": ["semaglutide", "tirzepatide", "liraglutide", "dulaglutide", "exenatide", "ozempic", "wegovy", "mounjaro", "zepbound"],
  "insulin_secretagogue": ["insulin", "glipizide", "glyburide", "glimepiride"],
  "vitamin_d": ["vitamin d", "vitamin d3", "cholecalciferol", "ergocalciferol", "calcitriol"],
  "calcium": ["calcium", "calcium carbonate", "calcium citrate"],
  "potassium": ["potassium", "potassium chloride", "potassium citrate", "salt substitute"],
  "fish_oil": ["fish oil", "omega-3", "omega 3", "epa", "dha"],
  "st_johns_wort": ["st john's wort", "st. john's wort", "hypericum"],
  "acetaminophen": ["acetaminophen", "paracetamol", "tylenol"],
  "lithium": ["lithium"],
  "methotrexate": ["methotrexate"],
};

// Words that label text uses for each class.
const CLASS_LABEL_TERMS: Record<string, string[]> = {
  ace_inhibitor: ["ace inhibitor", "angiotensin-converting enzyme", "angiotensin converting enzyme"],
  arb: ["angiotensin receptor blocker", "angiotensin ii receptor"],
  thiazide: ["thiazide"],
  loop_diuretic: ["loop diuretic"],
  potassium_sparing: ["potassium-sparing", "potassium sparing"],
  nsaid: ["nsaid", "nonsteroidal anti-inflammatory"],
  anticoagulant: ["anticoagulant", "warfarin"],
  antiplatelet: ["antiplatelet"],
  ssri_snri: ["ssri", "snri", "serotonin reuptake"],
  glp1: ["glp-1"],
  insulin_secretagogue: ["insulin", "sulfonylurea", "insulin secretagogue"],
  vitamin_d: ["vitamin d"],
  calcium: ["calcium supplement"],
  potassium: ["potassium supplement", "potassium-containing", "salt substitute"],
  lithium: ["lithium"],
  methotrexate: ["methotrexate"],
};

interface Rule { a: string[]; b: string[]; severity: InteractionFlag["severity"]; detail: string }

const RULES: Rule[] = [
  { a: ["nsaid"], b: ["ace_inhibitor", "arb", "thiazide", "loop_diuretic", "potassium_sparing"], severity: "caution",
    detail: "NSAIDs can blunt the blood-pressure-lowering effect of ACE inhibitors, ARBs and diuretics and, combined, raise the risk of kidney injury (especially with dehydration or hard endurance exercise)." },
  { a: ["nsaid"], b: ["anticoagulant", "antiplatelet", "ssri_snri"], severity: "avoid_unless_clinician_approves",
    detail: "NSAIDs together with blood thinners or SSRIs/SNRIs increase bleeding risk, including stomach bleeding." },
  { a: ["nsaid"], b: ["lithium", "methotrexate"], severity: "avoid_unless_clinician_approves",
    detail: "NSAIDs can raise blood levels of lithium and methotrexate." },
  { a: ["potassium"], b: ["ace_inhibitor", "arb", "potassium_sparing"], severity: "avoid_unless_clinician_approves",
    detail: "Potassium supplements or salt substitutes with ACE inhibitors, ARBs or potassium-sparing diuretics can cause dangerously high potassium." },
  { a: ["vitamin_d", "calcium"], b: ["thiazide"], severity: "caution",
    detail: "Vitamin D or calcium with thiazide diuretics can raise blood calcium." },
  { a: ["st_johns_wort"], b: ["ssri_snri", "anticoagulant", "antiplatelet", "glp1", "ace_inhibitor", "arb"], severity: "avoid_unless_clinician_approves",
    detail: "St John's wort changes how the liver clears many medicines and can cause serotonin syndrome with SSRIs/SNRIs." },
  { a: ["fish_oil"], b: ["anticoagulant", "antiplatelet"], severity: "caution",
    detail: "High-dose fish oil may add to the bleeding effect of blood thinners." },
  { a: ["glp1"], b: ["insulin_secretagogue"], severity: "caution",
    detail: "GLP-1 receptor agonists with insulin or sulfonylureas raise the risk of low blood sugar." },
];

const CONDITION_SYNONYMS: Record<string, string[]> = {
  kidney: ["kidney", "renal", "ckd"],
  liver: ["liver", "hepatic", "cirrhosis", "hepatitis"],
  heart: ["heart failure", "heart disease", "coronary", "cardiovascular", "heart attack", "myocardial"],
  hypertension: ["hypertension", "high blood pressure"],
  ulcer: ["ulcer", "gastrointestinal bleeding", "gi bleed", "stomach bleeding"],
  pregnancy: ["pregnan"],
  asthma: ["asthma"],
  cancer: ["cancer", "malignan", "tumor"],
  diabetes: ["diabetes", "diabetic"],
};

const CONDITION_RULES: { a: string[]; condition: string; severity: InteractionFlag["severity"]; detail: string }[] = [
  { a: ["nsaid"], condition: "kidney", severity: "avoid_unless_clinician_approves", detail: "NSAIDs can worsen kidney function." },
  { a: ["nsaid"], condition: "ulcer", severity: "avoid_unless_clinician_approves", detail: "NSAIDs raise the risk of stomach ulcers and bleeding." },
  { a: ["nsaid"], condition: "heart", severity: "avoid_unless_clinician_approves", detail: "NSAIDs carry a boxed warning for cardiovascular events and can worsen heart failure." },
  { a: ["nsaid"], condition: "hypertension", severity: "caution", detail: "NSAIDs can raise blood pressure." },
  { a: ["acetaminophen"], condition: "liver", severity: "avoid_unless_clinician_approves", detail: "Acetaminophen is processed by the liver; limits are lower with liver disease or regular alcohol use." },
];

export function classesOf(name: string): string[] {
  const n = name.toLowerCase();
  return Object.entries(CLASSES).filter(([, names]) => names.some((x) => n === x || n.includes(x) && x.length >= 4 || x.includes(n) && n.length >= 5)).map(([c]) => c);
}

function snippet(text: string, index: number, length: number): string {
  const start = Math.max(0, index - 120);
  const end = Math.min(text.length, index + length + 160);
  return `${start > 0 ? "…" : ""}${text.slice(start, end).trim()}${end < text.length ? "…" : ""}`;
}

/** Finds the first mention of any of `terms` in the label's safety sections. */
function findInLabel(label: LabelInfo, terms: string[]): { section: string; snippet: string } | null {
  const sections: [string, string][] = [
    ["boxed warning", label.boxed_warning], ["contraindications", label.contraindications],
    ["drug interactions", label.interactions], ["warnings", label.warnings],
  ];
  for (const [section, text] of sections) {
    const lower = text.toLowerCase();
    for (const t of terms) {
      if (t.length < 3) continue;
      const re = new RegExp(`\\b${t.toLowerCase().replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`, "i");
      const m = re.exec(lower);
      if (m) return { section, snippet: snippet(text, m.index, t.length) };
    }
  }
  return null;
}

function termsFor(name: string): string[] {
  const cls = classesOf(name);
  return [name, ...cls.flatMap((c) => CLASS_LABEL_TERMS[c] ?? [])];
}

export function crossCheck(compound: string, label: LabelInfo | null, userLabels: Map<string, LabelInfo | null>, ctx: MedContext): InteractionFlag[] {
  const flags: InteractionFlag[] = [];
  const add = (f: InteractionFlag) => {
    if (!flags.some((x) => x.with.toLowerCase() === f.with.toLowerCase() && x.source === f.source && x.kind === f.kind)) flags.push(f);
  };
  const compoundClasses = classesOf(compound).concat(label ? label.generic_names.flatMap(classesOf) : []);
  const others = ctx.compounds.filter((c) => c.name.toLowerCase() !== compound.toLowerCase());

  for (const other of others) {
    // 1a. Researched compound's label mentions the user's compound (or its class).
    if (label) {
      const hit = findInLabel(label, termsFor(other.name));
      if (hit) add({ with: other.name, kind: "drug_interaction", severity: "caution", source: `fda_label:${label.set_id}`,
        detail: `The FDA label for ${compound} mentions this in its ${hit.section} section: "${hit.snippet}"` });
    }
    // 1b. The user's compound's label mentions the researched compound (or its class).
    const otherLabel = userLabels.get(other.name) ?? null;
    if (otherLabel) {
      const terms = [compound, ...compoundClasses.flatMap((c) => CLASS_LABEL_TERMS[c] ?? [])];
      const hit = findInLabel(otherLabel, terms);
      if (hit) add({ with: other.name, kind: "drug_interaction", severity: "caution", source: `fda_label:${otherLabel.set_id}`,
        detail: `The FDA label for ${other.name} mentions ${compound} or its drug class in its ${hit.section} section: "${hit.snippet}"` });
    }
    // 2. Curated class rules (both directions).
    const otherClasses = classesOf(other.name);
    for (const r of RULES) {
      const forward = compoundClasses.some((c) => r.a.includes(c)) && otherClasses.some((c) => r.b.includes(c));
      const backward = compoundClasses.some((c) => r.b.includes(c)) && otherClasses.some((c) => r.a.includes(c));
      if (forward || backward) add({ with: other.name, kind: "drug_interaction", severity: r.severity, source: "curated_rule", detail: r.detail });
    }
  }

  // Conditions: curated rules + label text.
  for (const cond of ctx.conditions) {
    const lc = cond.toLowerCase();
    const keys = Object.entries(CONDITION_SYNONYMS).filter(([, syns]) => syns.some((s) => lc.includes(s))).map(([k]) => k);
    for (const r of CONDITION_RULES) {
      if (keys.includes(r.condition) && compoundClasses.some((c) => r.a.includes(c))) {
        add({ with: cond, kind: "condition", severity: r.severity, source: "curated_rule", detail: r.detail });
      }
    }
    if (label) {
      const terms = keys.flatMap((k) => CONDITION_SYNONYMS[k]).concat(lc.length >= 4 ? [lc] : []);
      const hit = findInLabel(label, terms);
      if (hit) add({ with: cond, kind: "condition", severity: "caution", source: `fda_label:${label.set_id}`,
        detail: `The FDA label for ${compound} mentions this condition in its ${hit.section} section: "${hit.snippet}"` });
    }
  }

  // Allergies.
  for (const allergy of ctx.allergies) {
    const la = allergy.toLowerCase();
    if (la.length >= 3 && (compound.toLowerCase().includes(la) || la.includes(compound.toLowerCase()) || classesOf(allergy).some((c) => compoundClasses.includes(c)))) {
      add({ with: allergy, kind: "allergy", severity: "avoid_unless_clinician_approves", source: "curated_rule",
        detail: `You listed an allergy to ${allergy}, which matches ${compound} or its drug class.` });
    }
  }

  // 3. No data: no FDA label for the researched compound → interaction data is essentially absent.
  if (!label && others.length) {
    add({
      with: others.map((o) => o.name).join(", "), kind: "no_data", severity: "unknown", source: "no_data",
      detail: `No FDA label was found for ${compound}, so there is no official interaction information with your current compounds. ` +
        "Missing data is not evidence of safety — ask a pharmacist or clinician to review the combination.",
    });
  }
  return flags;
}
