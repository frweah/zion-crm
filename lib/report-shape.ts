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
 * Eight, in roughly the order a case moves through. The list is the same list
 * as the check constraint on `notes.category` (0266, extended by 0269) and
 * `check-reports` asserts the two match - a category a screen offers and the
 * database refuses is a note somebody loses on save.
 *
 * Job placement is separate from Job development, which it was not at first.
 * The argument for folding them together was that placement is what
 * development is for; the argument against, which won, is that 36
 * authorizations name Job Placement on its own and a counselor reading about a
 * client who has been placed wants the placement, not a development section
 * with a hire buried in it.
 *
 * Personal is last and is not a service. It means the note is on the record
 * because the practice needs it to do the work, and is nobody else's business:
 * it is never in a report and never in an export to a counselor, and the
 * database narrows its roles to Admin and Case Manager whatever the screen
 * asked for.
 */
export const NOTE_CATEGORIES = [
  "Job development",
  "Job placement",
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
      return "Job development";
    case "Job Placement":
      return "Job placement";
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
  /**
   * Where something stands, rather than something that happened.
   *
   * One line of standing fact for the section: a placement's hire date and
   * which retention checks have been recorded. It carries `on` like every
   * other line, because the month slices on the date and a line without one
   * would fall out of a week - but what the date means is "as at", not "this
   * is when it happened", so it is set to the end of the period and the
   * renderer prints it without a date column and above the dated entries.
   *
   * Added because a counselor reading November about somebody hired in
   * September was told nothing about the hire. Retention is the one fact a
   * placement report exists to carry, and a report that only ever shows the
   * current month cannot carry it.
   */
  standing?: boolean;
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
