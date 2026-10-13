// "Meaningful update" filter for followed research interests. Pure: compares the last-seen
// snapshot with freshly retrieved evidence. Only these events create alerts:
//   - a new meta-analysis, systematic review or randomized controlled trial in PubMed
//   - an FDA label revision (new effective date) or a newly found FDA label
//   - a ClinicalTrials.gov trial that newly posted results, or newly completed (interventional)
// Ordinary new papers (case reports, narrative reviews, animal studies, …) never alert.
import type { Citation } from "./evidence.ts";
import type { Evidence } from "./sources.ts";

export interface Snapshot {
  pubmed: string[];
  trials: Record<string, { status: string; has_results: boolean }>;
  label: { set_id: string; effective_time: string | null } | null;
}

export type AlertKind = "new_meta_analysis" | "new_systematic_review" | "new_rct" | "fda_label_update" | "trial_results_posted" | "trial_completed";

export interface AlertDraft { kind: AlertKind; title: string; summary: string; citation: Citation }

export function snapshotOf(ev: Evidence, prev: Snapshot | null): Snapshot {
  const pubmed = [...new Set([...(prev?.pubmed ?? []), ...ev.citations.filter((c) => c.source === "pubmed").map((c) => c.id)])].slice(-500);
  const trials: Snapshot["trials"] = { ...(prev?.trials ?? {}) };
  for (const t of ev.trials) trials[t.nct] = { status: t.status, has_results: t.has_results };
  const label = ev.label ? { set_id: ev.label.set_id, effective_time: ev.label.effective_time } : prev?.label ?? null;
  return { pubmed, trials, label };
}

const KIND_TEXT: Record<AlertKind, string> = {
  new_meta_analysis: "New meta-analysis",
  new_systematic_review: "New systematic review",
  new_rct: "New randomized controlled trial",
  fda_label_update: "FDA label updated",
  trial_results_posted: "Trial results posted",
  trial_completed: "Clinical trial completed",
};

export function meaningfulUpdates(topic: string, prev: Snapshot | null, ev: Evidence): AlertDraft[] {
  if (!prev) return []; // first check only records a baseline
  const alerts: AlertDraft[] = [];
  const seen = new Set(prev.pubmed);
  const add = (kind: AlertKind, c: Citation, extra = "") =>
    alerts.push({ kind, title: `${KIND_TEXT[kind]}: ${topic}`, summary: `${c.title}${c.year ? ` (${c.year})` : ""}${extra}`.slice(0, 500), citation: c });

  for (const c of ev.citations) {
    if (c.source === "pubmed" && !seen.has(c.id)) {
      if (c.study_kind === "meta_analysis") add("new_meta_analysis", c);
      else if (c.study_kind === "systematic_review") add("new_systematic_review", c);
      else if (c.study_kind === "rct") add("new_rct", c);
    }
  }
  for (const t of ev.trials) {
    const before = prev.trials[t.nct];
    const c = ev.citations.find((x) => x.source === "clinicaltrials" && x.id === t.nct);
    if (!c) continue;
    if (t.has_results && (!before || !before.has_results)) add("trial_results_posted", c, " — results are now posted on ClinicalTrials.gov");
    else if (before && before.status !== "COMPLETED" && t.status === "COMPLETED" && t.study_type === "INTERVENTIONAL") add("trial_completed", c);
  }
  if (ev.label) {
    const c = ev.citations.find((x) => x.source === "fda_label" && x.id === ev.label!.set_id);
    const changed = !prev.label || prev.label.set_id !== ev.label.set_id || prev.label.effective_time !== ev.label.effective_time;
    if (c && changed) add("fda_label_update", c, ev.label.effective_time ? ` — label effective ${ev.label.effective_time}` : "");
  }
  return alerts;
}
