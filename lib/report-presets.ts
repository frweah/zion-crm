/**
 * What a counselor is being told about.
 *
 * A counselor chasing a job development authorization does not want three
 * pages of coaching hours, and one asking how a placement is holding up does
 * not want the billing table. The presets are the difference between a report
 * that gets read and one that gets filed, so each is a named subset of the
 * same sections rather than a differently written report — the underlying
 * facts stay the same whichever is chosen.
 *
 * Kept apart from lib/report.ts, which is server-only: the picker on the
 * Report tab is a client component and needs the labels.
 */
export type ReportSection =
  | "summary"
  | "activity"
  | "hours"
  | "jobs"
  | "placements"
  | "contacts"
  | "tasks"
  | "billing"
  | "next";

export type ReportPresetKey = "general" | "development" | "coaching" | "placement";

export const REPORT_PRESETS: {
  key: ReportPresetKey;
  label: string;
  blurb: string;
  sections: ReportSection[];
}[] = [
  {
    key: "general",
    label: "General progress",
    blurb: "Everything in the period — the report that goes with an invoice.",
    sections: [
      "summary",
      "activity",
      "hours",
      "jobs",
      "placements",
      "contacts",
      "tasks",
      "billing",
      "next",
    ],
  },
  {
    key: "development",
    label: "Job development update",
    blurb: "Where the job search has got to: applications, employers, interviews.",
    sections: ["summary", "jobs", "activity", "contacts", "next"],
  },
  {
    key: "coaching",
    label: "Job coaching update",
    blurb: "Supports delivered on the job, the hours behind them, and how it is holding.",
    sections: ["summary", "hours", "activity", "placements", "next"],
  },
  {
    key: "placement",
    label: "Interview / placement update",
    blurb: "An interview, an offer, a start date, a 30/60/90-day check.",
    sections: ["summary", "jobs", "placements", "activity", "next"],
  },
];

export function presetByKey(key: string | null | undefined) {
  return REPORT_PRESETS.find((p) => p.key === key) ?? REPORT_PRESETS[0];
}
