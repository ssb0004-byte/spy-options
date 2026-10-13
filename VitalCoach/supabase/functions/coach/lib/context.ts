// Builds the minimal, deterministic context the coach sees. All numbers are computed here in
// code — the language model never does the arithmetic and never sees raw history it doesn't need.

export interface Rows {
  profile: Record<string, any> | null;
  preferences: Record<string, any> | null;
  goals: Record<string, any>[];
  measurements: Record<string, any>[];       // last 90 days, non-deleted
  substances: Record<string, any>[];         // non-deleted
  regimens: Record<string, any>[];           // non-deleted
  administrations: Record<string, any>[];    // last 14 days
  symptoms: Record<string, any>[];           // last 14 days
  pain: Record<string, any>[];               // last 14 days
  adverseEffects: Record<string, any>[];     // unresolved
  memories: Record<string, any>[];           // status = active
}

export interface CoachContext {
  generated_for_date: string;
  notes: string[];
  profile: Record<string, unknown>;
  goals: string[];
  coach_style: string;
  units: "metric" | "imperial";
  measurements: Record<string, unknown>[];
  routine: Record<string, unknown>[];
  dose_log_last_14_days: Record<string, unknown>[];
  check_ins_last_14_days: Record<string, unknown>;
  pain_last_14_days: Record<string, unknown>[];
  open_side_effects: Record<string, unknown>[];
  remembered_about_user: string[];
}

const KG_PER_LB = 0.45359237;

const MASS_KINDS = new Set(["body_mass", "lean_body_mass", "fat_free_mass", "skeletal_muscle_mass", "scale_muscle_mass"]);
const LENGTH_KINDS = new Set(["waist_circumference", "hip_circumference", "chest_circumference", "arm_circumference", "thigh_circumference", "height"]);
const CUMULATIVE = new Set(["step_count", "active_energy"]);

const UNIT_LABELS: Record<string, string> = {
  body_fat_percentage: "%", body_mass_index: "kg/m²", heart_rate: "bpm", resting_heart_rate: "bpm",
  hrv_sdnn: "ms", step_count: "steps/day", active_energy: "kcal/day",
};

const LABELS: Record<string, string> = {
  body_mass: "Weight", body_fat_percentage: "Body fat % (scale estimate unless noted)", lean_body_mass: "Lean body mass (scale estimate)",
  fat_free_mass: "Fat-free mass", skeletal_muscle_mass: "Skeletal muscle mass", scale_muscle_mass: "Scale 'muscle mass' (proprietary estimate)",
  body_mass_index: "BMI", waist_circumference: "Waist", hip_circumference: "Hips", chest_circumference: "Chest",
  arm_circumference: "Upper arm", thigh_circumference: "Thigh", heart_rate: "Average heart rate", resting_heart_rate: "Resting heart rate",
  hrv_sdnn: "HRV (SDNN)", step_count: "Steps", active_energy: "Active energy", height: "Height",
};

export function round(n: number, digits: number): number {
  const f = 10 ** digits;
  return Math.round(n * f) / f;
}

export function displayValue(kind: string, value: number, units: "metric" | "imperial"): { value: number; unit: string } {
  if (MASS_KINDS.has(kind)) return units === "imperial" ? { value: round(value / KG_PER_LB, 1), unit: "lb" } : { value: round(value, 1), unit: "kg" };
  if (LENGTH_KINDS.has(kind)) return units === "imperial" ? { value: round(value / 2.54, 1), unit: "in" } : { value: round(value, 1), unit: "cm" };
  return { value: round(value, kind === "step_count" || kind === "active_energy" ? 0 : 1), unit: UNIT_LABELS[kind] ?? "" };
}

/** Local calendar day (YYYY-MM-DD) of an instant in a time zone. */
export function localDay(iso: string, timeZone: string): string {
  const d = new Date(iso);
  return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}

function daysBetween(a: string, b: string): number {
  return Math.round((Date.parse(b + "T00:00:00Z") - Date.parse(a + "T00:00:00Z")) / 86_400_000);
}

export function ageOn(dob: string | null | undefined, today: string): number | null {
  if (!dob) return null;
  const [y, m, d] = dob.split("-").map(Number);
  const [ty, tm, td] = today.split("-").map(Number);
  let age = ty - y;
  if (tm < m || (tm === m && td < d)) age -= 1;
  return age >= 0 && age < 130 ? age : null;
}

interface DailyPoint { day: string; value: number; quality: string }

function daily(rows: Record<string, any>[], kind: string, timeZone: string): DailyPoint[] {
  const byDay = new Map<string, { sum: number; n: number; qualities: Set<string> }>();
  for (const r of rows) {
    if (r.kind !== kind || typeof r.value !== "number") continue;
    const day = localDay(r.start_at, timeZone);
    const e = byDay.get(day) ?? { sum: 0, n: 0, qualities: new Set<string>() };
    e.sum += r.value; e.n += 1; e.qualities.add(r.quality);
    byDay.set(day, e);
  }
  const order = ["self_reported", "derived", "estimated", "measured"];
  return [...byDay.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([day, e]) => ({
    day,
    value: CUMULATIVE.has(kind) ? e.sum : e.sum / e.n,
    quality: order.find((q) => e.qualities.has(q)) ?? "measured",
  }));
}

function mean(xs: number[]): number | null {
  return xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;
}

export function summarizeMetric(rows: Record<string, any>[], kind: string, today: string, timeZone: string, units: "metric" | "imperial") {
  const pts = daily(rows, kind, timeZone);
  if (!pts.length) return null;
  const last = pts[pts.length - 1];
  const inWindow = (from: number, to: number) => pts.filter((p) => { const age = daysBetween(p.day, today); return age >= from && age <= to; });
  const recent = mean(inWindow(0, 6).map((p) => p.value));
  const prior = mean(inWindow(21, 34).map((p) => p.value));
  const sources = [...new Set(rows.filter((r) => r.kind === kind).map((r) => r.source_name).filter(Boolean))].slice(0, 3);
  const lastDisplay = displayValue(kind, last.value, units);
  const out: Record<string, unknown> = {
    metric: LABELS[kind] ?? kind,
    latest: `${lastDisplay.value} ${lastDisplay.unit}`.trim(),
    latest_date: last.day,
    quality: last.quality,
    days_with_data_last_90: pts.length,
    sources,
  };
  if (recent !== null && prior !== null) {
    const r = displayValue(kind, recent, units), p = displayValue(kind, prior, units);
    out["avg_last_7_days"] = `${r.value} ${r.unit}`.trim();
    out["avg_3_to_5_weeks_ago"] = `${p.value} ${p.unit}`.trim();
    out["change"] = `${round(r.value - p.value, 1) > 0 ? "+" : ""}${round(r.value - p.value, 1)} ${r.unit}`.trim();
  } else {
    out["trend"] = "not enough data to compare periods";
  }
  return out;
}

function describeSchedule(s: Record<string, any> | null | undefined): string {
  if (!s) return "unknown schedule";
  const times = Array.isArray(s.times) ? s.times.map((t: any) => `${String(t.hour).padStart(2, "0")}:${String(t.minute).padStart(2, "0")}`).join(", ") : "";
  let base: string;
  switch (s.frequency) {
    case "daily": base = `daily at ${times}`; break;
    case "every_n_days": base = `every ${s.interval_days} days at ${times}`; break;
    case "weekdays": base = `on weekdays ${JSON.stringify(s.weekdays ?? [])} (1=Sun) at ${times}`; break;
    case "as_needed": base = "as needed"; break;
    default: base = "custom schedule";
  }
  if (s.cycle_on_days != null && s.cycle_off_days != null) base += `, cycle ${s.cycle_on_days} days on / ${s.cycle_off_days} off`;
  return base;
}

export function buildContext(rows: Rows, today: string, timeZone: string): CoachContext {
  const units: "metric" | "imperial" = rows.preferences?.unit_system === "imperial" ? "imperial" : "metric";
  const p = rows.profile ?? {};
  const profile: Record<string, unknown> = {};
  const age = ageOn(p.date_of_birth, today);
  if (age !== null) profile.age = age;
  if (p.physiological_sex && p.physiological_sex !== "prefer_not_to_say") profile.physiological_sex = p.physiological_sex;
  if (p.sex_context_note) profile.user_provided_context = p.sex_context_note;
  if (typeof p.height_cm === "number") profile.height = units === "imperial" ? `${round(p.height_cm / 2.54, 1)} in` : `${round(p.height_cm, 1)} cm`;
  if (p.activity_level) profile.activity_level = p.activity_level;
  for (const key of ["medical_conditions", "allergies", "injuries"]) {
    if (Array.isArray(p[key]) && p[key].length) profile[key] = p[key].slice(0, 20);
  }
  if (p.display_name) profile.first_name = p.display_name;

  const kinds = [...new Set(rows.measurements.map((m) => m.kind as string))].sort();
  const measurements = kinds.map((k) => summarizeMetric(rows.measurements, k, today, timeZone, units)).filter(Boolean) as Record<string, unknown>[];

  const activeIds = new Set(rows.substances.filter((s) => s.status === "active").map((s) => s.id));
  const routine = rows.substances
    .filter((s) => ["active", "planned", "paused"].includes(s.status))
    .slice(0, 40)
    .map((s) => {
      const regs = rows.regimens.filter((r) => r.user_substance_id === s.id)
        .sort((a, b) => String(b.start_date).localeCompare(String(a.start_date)));
      const current = regs.find((r) => r.start_date <= today && (!r.end_date || r.end_date >= today)) ?? regs[0];
      const item: Record<string, unknown> = { name: s.name, category: s.category, status: s.status };
      if (s.formulation) item.formulation = s.formulation;
      if (s.indication) item.reason = s.indication;
      if (s.is_prescribed) item.prescribed = true;
      if (current) {
        item.current_dose = `${Number(current.dose_amount)} ${current.dose_unit}, ${current.route}`;
        item.schedule = describeSchedule(current.schedule);
        item.since = current.start_date;
        if (current.end_date) item.until = current.end_date;
      }
      const earlier = regs.filter((r) => r !== current).slice(0, 3)
        .map((r) => `${Number(r.dose_amount)} ${r.dose_unit} from ${r.start_date}${r.end_date ? ` to ${r.end_date}` : ""}`);
      if (earlier.length) item.previous_doses = earlier;
      return item;
    });

  // Effective records only: drop superseded and voided entries.
  const superseded = new Set(rows.administrations.map((a) => a.supersedes_id).filter(Boolean));
  const effective = rows.administrations.filter((a) => !superseded.has(a.id) && a.action !== "voided");
  const nameById = new Map(rows.substances.map((s) => [s.id, s.name]));
  const logBy = new Map<string, Record<string, number>>();
  for (const a of effective) {
    const name = nameById.get(a.user_substance_id) ?? "unknown";
    const e = logBy.get(name) ?? { taken: 0, skipped: 0, missed: 0 };
    if (a.action in e) e[a.action] += 1;
    logBy.set(name, e);
  }
  const dose_log_last_14_days = [...logBy.entries()].map(([name, c]) => ({ name, ...c }));

  const avg = (field: string) => {
    const xs = rows.symptoms.map((s) => s[field]).filter((x) => typeof x === "number");
    const m = mean(xs);
    return m === null ? null : { average: round(m, 1), answers: xs.length };
  };
  const check_ins_last_14_days: Record<string, unknown> = { number_of_check_ins: rows.symptoms.length };
  for (const [field, label] of [["wellbeing", "wellbeing_1_to_5"], ["energy", "energy_1_to_5"], ["cognitive_clarity", "mental_clarity_1_to_5"], ["stiffness", "stiffness_0_to_10"]]) {
    const a = avg(field);
    if (a) check_ins_last_14_days[label] = a;
  }
  const notes = rows.symptoms.map((s) => s.side_effects_note).filter(Boolean).slice(-3);
  if (notes.length) check_ins_last_14_days.recent_side_effect_notes = notes.map((n: string) => n.slice(0, 200));

  const painBy = new Map<string, number[]>();
  for (const pe of rows.pain) {
    const arr = painBy.get(pe.location) ?? [];
    arr.push(pe.severity);
    painBy.set(pe.location, arr);
  }
  const pain_last_14_days = [...painBy.entries()].map(([location, sev]) => ({
    location, entries: sev.length, highest_0_to_10: Math.max(...sev), average_0_to_10: round(mean(sev)!, 1),
  }));

  const open_side_effects = rows.adverseEffects.slice(0, 10).map((e) => ({
    summary: String(e.summary).slice(0, 200), severity: e.severity, since: String(e.onset_at).slice(0, 10),
    substance: e.user_substance_id ? nameById.get(e.user_substance_id) ?? null : null,
  }));

  const contextNotes = [
    "Only the data below is known. Anything not listed is unknown — do not assume or invent it.",
    "Scale body-composition values are bioimpedance estimates with meaningful measurement error.",
    "Dose log counts are what the user logged; days without a log are unknown, not 'taken'.",
  ];
  if (!rows.measurements.length && !rows.symptoms.length) contextNotes.push("The user has little or no synced data yet.");
  if (activeIds.size === 0) contextNotes.push("No active substances are recorded.");

  return {
    generated_for_date: today,
    notes: contextNotes,
    profile,
    goals: rows.goals.filter((g) => g.is_active !== false).map((g) => g.goal),
    coach_style: rows.preferences?.coach_personality ?? "balanced",
    units,
    measurements,
    routine,
    dose_log_last_14_days,
    check_ins_last_14_days,
    pain_last_14_days,
    open_side_effects,
    remembered_about_user: rows.memories.slice(0, 30).map((m) => `[${m.category}] ${String(m.content).slice(0, 300)}`),
  };
}
