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

/**
 * The service a note is about.
 *
 * Seven, in the order the brief gives them, which is also roughly the order a
 * case moves through. The list is the same list as the check constraint on
 * `notes.category` (0266) and `check-reports` asserts the two match - a
 * category a screen offers and the database refuses is a note somebody loses.
 *
 * Personal is last and is not a service. It means the note is on the record
 * because the practice needs it to do the work, and is nobody else's business:
 * it is never in a report and never in an export to a counselor, and the
 * database narrows its roles to Admin and Case Manager whatever the screen
 * asked for.
 */
export const NOTE_CATEGORIES = [
  "Job development",
  "Job coaching",
  "Job search",
  "Assessment",
  "Life skills",
  "General progress",
  "Personal",
] as const;

export type NoteCategory = (typeof NOTE_CATEGORIES)[number];

export const PERSONAL: NoteCategory = "Personal";

/**
 * A category off a form, or nothing.
 *
 * A function rather than a check written out at the call site, so that
 * check-reports can run the rule instead of reading the shape of it. The first
 * version of that check matched `NOTE_CATEGORIES.includes(...)` in the source
 * and passed happily with `false &&` in front of it - a question asked merely
 * near the rule, which is the one failure CLAUDE.md names twice.
 *
 * Returning null rather than a default is the point: the screen always sends
 * one, so nothing arriving means the box was emptied deliberately and the
 * right answer is to ask again, not to pick.
 */
export function noteCategoryFromForm(value: unknown): NoteCategory | null {
  const asked = typeof value === "string" ? value.trim() : "";
  return (NOTE_CATEGORIES as readonly string[]).includes(asked) ? (asked as NoteCategory) : null;
}

/**
 * The category a client's stage implies, matching `category_for_stage` in the
 * database exactly. Here as well as there because the screen guesses before it
 * writes - a picker that opens on the likely answer is a picker people use,
 * and one that opens blank is a column full of General progress.
 */
export function categoryForStage(stage: string | null | undefined): NoteCategory {
  switch (stage) {
    case "Job Development":
    case "Job Placement":
      return "Job development";
    case "Job Coaching":
      return "Job coaching";
    case "Job Search":
      return "Job search";
    case "Assessment":
      return "Assessment";
    case "Life Skills":
      return "Life skills";
    default:
      return "General progress";
  }
}

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
