/**
 * What a report is made of, with nothing to load it from.
 *
 * These types and this one constant are the shape of a report and nothing
 * else - no database, no `server-only`, no imports at all. That is the whole
 * reason the file exists: `lib/report-period.ts` builds this shape by reading
 * the record and so can never run outside a request, and
 * `scripts/check-reports.mjs` has to be able to run the renderer over made-up
 * content before every build to assert what reaches a counselor.
 *
 * `lib/report-period.ts` re-exports everything here, so nothing else had to
 * change when it moved.
 */

/** The section a line goes under when the client holds no authorization for it. */
export const GENERAL = "General";

/** What a line came from. Kept with the line so a screen can group or hide by it. */
export type LineKind =
  | "hours"
  | "appointment"
  | "note"
  | "mail"
  | "job"
  | "day"
  | "placement"
  | "contact"
  | "assessment";

export type ReportLine = {
  /** The date the record gives it, which is what the month slices on. */
  on: string;
  kind: LineKind;
  text: string;
  /**
   * Billable hours, on an hours line and nowhere else.
   *
   * Carried as a number rather than left to be read back out of `text`,
   * because the month adds these up and a month that re-parses its own prose
   * is a month that will one day add up a sentence.
   */
  hours?: number;
};

export type ReportSection = {
  /** The authorized service this section is about, or "General". */
  service: string;
  code: string;
  lines: ReportLine[];
};

export type PeriodContent = {
  from: string;
  to: string;
  sections: ReportSection[];
  /** Notes whose words were left out because the note is not for everybody. */
  withheld: number;
  /** Billable service hours in the period. */
  hours: number;
};
