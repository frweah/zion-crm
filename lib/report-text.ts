import { GENERAL, type PeriodContent, type ReportLine } from "./report-shape.ts";

/**
 * The monthly report as words.
 *
 * One renderer, for the same reason the forms have one: the screen the owner
 * reads before signing, the PDF the counselor receives, and the copy filed on
 * the client record all have to be the same document. A screen that lays the
 * sections out itself would be a second renderer, and the day the two
 * disagreed the practice would have signed something it had not read.
 *
 * So the screen renders `monthlyReportLines` and the PDF draws the same
 * array, and the only difference between them is the paper.
 *
 * No imports from the database and nothing async, so `scripts/check-reports.mjs`
 * can run it over made-up content and assert what reaches a counselor.
 */

/**
 * A month, as the month builder leaves it.
 *
 * Declared here rather than imported from lib/report-drafts.ts, which cannot
 * be loaded outside a request: the renderer has to run in a check, and the
 * two weeks-and-gaps fields are the whole of what the month adds.
 */
export type MonthlyShape = PeriodContent & {
  weeks: { week_start: string; status: string; note: string }[];
  gaps: { from: string; to: string }[];
};

export type ReportLineOut = {
  /** How the line is set: a heading, a dated entry, or plain text. */
  as: "title" | "heading" | "label" | "entry" | "text" | "blank";
  text: string;
  /** On an entry, the date in its own column. */
  on?: string;
};

export type MonthlyMeta = {
  clientName: string;
  clientNo: string | number | null;
  agencyId: string | null;
  counselorName: string | null;
  ownerName: string | null;
  /** The summary as somebody left it. Empty falls back to the drafted one. */
  summary: string;
  signedBy?: string | null;
  signedAt?: string | null;
};

const MONTH = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { month: "long", year: "numeric" });

const DAY = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", { day: "numeric", month: "short" });

const LONG = (iso: string) =>
  new Date(`${iso}T12:00:00Z`).toLocaleDateString("en-US", {
    day: "numeric",
    month: "long",
    year: "numeric",
  });

const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

/** Round to one place and drop a trailing zero, so 2.0 reads as 2. */
const hrs = (n: number) => {
  const r = Math.round(n * 10) / 10;
  return Number.isInteger(r) ? String(r) : r.toFixed(1);
};

/**
 * The summary, drafted from what the month contains.
 *
 * Counted, never characterised: "12.5 hours over 7 visits" is in the record
 * and "good progress" is not. Five lines is the brief's cap and it is a cap
 * on what is offered, not on what the owner may then write - they replace
 * this with their own words, and the whole point of drafting it is that
 * replacing something is quicker than starting.
 *
 * A month with nothing in it says so in one line. That sentence is the most
 * useful one this function produces: it is how a counselor finds out that a
 * month went by without the service being delivered, which is exactly what
 * the practice was failing to tell them.
 */
export const MOST_SUMMARY_LINES = 5;

export function draftMonthlySummary(content: MonthlyShape): string {
  const lines: string[] = [];
  const all = content.sections.flatMap((s) => s.lines);
  const of = (kind: ReportLine["kind"]) => all.filter((l) => l.kind === kind);

  // Hours, per authorized service, because that is how they were authorized.
  const byService = content.sections
    .map((s) => ({
      service: s.service,
      hours: s.lines.reduce((t, l) => t + (l.hours ?? 0), 0),
      visits: s.lines.filter((l) => l.kind === "hours").length,
    }))
    .filter((s) => s.hours > 0);

  if (byService.length > 0) {
    lines.push(
      byService
        .map((s) =>
          s.service === GENERAL
            ? `${hrs(s.hours)} hours over ${plural(s.visits, "visit")}`
            : `${s.service}: ${hrs(s.hours)} hours over ${plural(s.visits, "visit")}`,
        )
        .join("; ") + ".",
    );
  } else {
    lines.push("No service hours were logged this month.");
  }

  const kept = of("appointment");
  if (kept.length > 0) lines.push(`${plural(kept.length, "appointment")} on the calendar.`);

  const jobs = of("job");
  const placed = of("placement");
  if (jobs.length > 0) lines.push(`${plural(jobs.length, "job application")} moved this month.`);
  if (placed.length > 0) lines.push(placed.map((l) => l.text).join("; ") + ".");

  const assessments = of("assessment");
  if (assessments.length > 0) {
    lines.push(assessments.map((l) => l.text).join("; ") + ".");
  }

  // Five is the brief's cap and this is the only place it is applied, so a
  // sixth kind of line added above cannot quietly make the summary six long.
  return lines.slice(0, MOST_SUMMARY_LINES).join("\n");
}

/**
 * The whole report, as lines something can draw.
 *
 * The order is the brief's: who it is about, the summary, then one section per
 * service with its dated entries. A service the client holds an authorization
 * for appears whether or not anything happened under it and says "No activity
 * recorded"; a service they do not hold is not a section at all, which is the
 * brief's "empty sections omitted".
 *
 * What is deliberately not in it: the stretches of the month no weekly report
 * covered. The days themselves are here - they were read straight off the
 * record - and whether a member of staff confirmed them is said plainly under
 * "How this was prepared". A counselor reading this needs to know what the
 * account rests on; they do not need our internal complaint about which
 * Monday somebody missed, and 34 CFR 361.38 is the reason to tell them the
 * first and not the second.
 */
export function monthlyReportLines(
  month: string,
  content: MonthlyShape,
  meta: MonthlyMeta,
): ReportLineOut[] {
  const out: ReportLineOut[] = [];
  const say = (as: ReportLineOut["as"], text: string, on?: string) => out.push({ as, text, on });

  say("title", "Monthly progress report");
  say(
    "heading",
    [
      meta.clientName,
      meta.clientNo ? `Client #${meta.clientNo}` : null,
      meta.agencyId ? `USOR ID ${meta.agencyId}` : null,
    ]
      .filter(Boolean)
      .join("  ·  "),
  );
  say("text", `${MONTH(month)} — ${LONG(content.from)} to ${LONG(content.to)}`);
  if (meta.counselorName) say("text", `Counselor: ${meta.counselorName}`);
  if (meta.ownerName) say("text", `Prepared by: ${meta.ownerName}`);
  say("blank", "");

  say("label", "Summary");
  for (const line of (meta.summary.trim() || draftMonthlySummary(content)).split("\n")) {
    say("text", line);
  }
  say("blank", "");

  for (const section of content.sections) {
    say("label", section.code && section.code !== "—" ? `${section.service} (${section.code})` : section.service);
    if (section.lines.length === 0) {
      say("text", "No activity recorded.");
    } else {
      for (const line of section.lines) {
        say(
          "entry",
          line.hours ? `${line.text} — ${hrs(line.hours)} hr` : line.text,
          line.on,
        );
      }
    }
    say("blank", "");
  }

  if (content.sections.length === 0) {
    say("label", "Services");
    say("text", "No service was authorized for this month.");
    say("blank", "");
  }

  // ── what the account rests on ──────────────────────────────
  say("label", "How this was prepared");
  say("text", `${hrs(content.hours)} billable hours recorded in the month.`);
  const confirmed = content.weeks.filter((w) => w.status === "Confirmed");
  if (content.weeks.length === 0) {
    say("text", "Taken from the client record. No weekly account was kept for this month.");
  } else {
    say(
      "text",
      `${confirmed.length} of ${plural(content.weeks.length, "week")} confirmed by the staff member who did the work.`,
    );
    for (const week of confirmed.filter((w) => w.note.trim())) {
      say("entry", week.note.trim(), week.week_start);
    }
  }
  if (content.gaps.length > 0) {
    say(
      "text",
      `${plural(content.gaps.length, "stretch", "stretches")} of the month taken from the record without a weekly account.`,
    );
  }
  if (content.withheld > 0) {
    say(
      "text",
      `${plural(content.withheld, "note")} on this client's record ${
        content.withheld === 1 ? "is" : "are"
      } not included here.`,
    );
  }

  return out;
}

/** The same report as plain text, for an email body or a filed copy. */
export function monthlyReportText(
  month: string,
  content: MonthlyShape,
  meta: MonthlyMeta,
): string {
  return monthlyReportLines(month, content, meta)
    .map((l) => {
      if (l.as === "blank") return "";
      if (l.as === "title") return l.text.toUpperCase();
      if (l.as === "label") return l.text.toUpperCase();
      if (l.as === "entry") return `  ${(l.on ? DAY(l.on) : "").padEnd(9)}${l.text}`;
      return l.text;
    })
    .join("\n");
}
