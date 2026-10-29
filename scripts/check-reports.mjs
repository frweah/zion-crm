/**
 * The weekly and monthly reports, checked where no database is needed.
 *
 *   node scripts/check-reports.mjs   (also runs before every build)
 *
 * Three kinds of thing can be wrong here and none of them throws.
 *
 * **The week arithmetic.** The month is assembled out of weeks, so a month
 * that begins on a Thursday has a week in two months at once, five times a
 * year. Lose that week and the report is missing four days; count it twice and
 * the hours are wrong. Nothing errors either way - the report is simply not
 * what happened. So the real functions are run over every day of two years
 * here: every day of every month belongs to exactly one of the weeks the
 * month is assembled from, and each Monday is a Monday.
 *
 * The clock change is in that: `addDays` and `mondayOf` go through UTC because
 * the practice is in Mountain time, and the weeks of 8 March and 1 November
 * are where a local-time version would quietly land a day out.
 *
 * **The note gate.** A note narrowed below the four roles an ordinary note is
 * visible to is narrowed on purpose, and a monthly report is signed and posted
 * to the state. One conditional in lib/report-period.ts keeps those two facts
 * apart. It is checked here because it is one line, it has no error case, and
 * a report with a held-back note's words in it looks exactly like a good one.
 *
 * **What reaches a counselor.** The monthly report is signed and posted to
 * the state, and the renderer that decides what is in it has no error case
 * either: a held-back note whose words were copied in reads exactly like a
 * good report, and so does one that silently dropped a section. So the real
 * renderer is run over made-up content here, and what is asserted is what a
 * counselor would be holding.
 *
 * **Whether anything is drafted at all.** The drafts are made by a scheduled
 * job, so if that job is not scheduled the whole feature is silently absent -
 * every screen works and every list is empty. The schedule itself lives in the
 * database and is asserted by supabase/verify_monthly_reports.sql; what is
 * asserted here is the half that is in the repository: a migration that
 * schedules it daily, and a route that decides the day in the practice's own
 * timezone rather than the server's.
 */
import { readFileSync, readdirSync } from "node:fs";
import {
  addDays,
  lastWeekOf,
  mondayOf,
  monthEndOf,
  monthStartOf,
  monthlyDueOn,
  previousMonthOf,
  weeklyDueOn,
  weeksAcross,
} from "../lib/report-weeks.ts";
import {
  MOST_SUMMARY_LINES,
  draftMonthlySummary,
  monthlyReportLines,
} from "../lib/report-text.ts";
import {
  NOTE_CATEGORIES,
  PERSONAL,
  categoryForStage,
  noteCategoryFromForm,
} from "../lib/report-shape.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const src = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

/** The day of the week a date falls on, counted the way ISO does: Monday is 1. */
const isoDay = (date) => ((new Date(`${date}T00:00:00Z`).getUTCDay() + 6) % 7) + 1;

/**
 * The dates from one to another, collected rather than walked in place.
 *
 * Capped, and the cap is the point. The first version of this file walked
 * `for (let d = from; d <= to; d = addDays(d, 1))`, and the fault put back to
 * test it - a date read with local getters out of a UTC instant - made
 * `addDays` return the day it was given at the clock change. The loop never
 * advanced, and a check that hangs before every build is worse than the bug
 * it was looking for. So a step that does not move is a named failure.
 */
function stepping(from, to, step, cap, what) {
  const out = [];
  let d = from;
  while (d <= to) {
    out.push(d);
    const next = step(d);
    if (next <= d) {
      fail(`${what} did not get past ${d}`);
      return out;
    }
    d = next;
    if (out.length > cap) {
      fail(`${what} from ${from} did not reach ${to} inside ${cap} steps`);
      return out;
    }
  }
  return out;
}

const everyDay = (from, to) => stepping(from, to, (d) => addDays(d, 1), 1000, "stepping a day at a time");
const everyMonth = (from, to) =>
  stepping(from, to, (m) => monthStartOf(addDays(monthEndOf(m), 1)), 60, "stepping a month at a time");
const everyWeek = (from, to) => stepping(from, to, (w) => addDays(w, 7), 200, "stepping a week at a time");

// ── 1. every Monday is a Monday ───────────────────────────────

const allDays = everyDay("2026-01-01", "2027-12-31");
let days = 0;
let mondayTrouble = 0;
for (const d of allDays) {
  days++;
  const monday = mondayOf(d);
  if (isoDay(monday) !== 1) {
    if (mondayTrouble++ === 0) fail(`mondayOf(${d}) is ${monday}, which is not a Monday`);
  }
  if (monday > d || addDays(monday, 6) < d) {
    if (mondayTrouble++ === 0) fail(`${d} is not inside the week starting ${monday}`);
  }
}
if (days !== 730) fail(`stepping a day at a time over 2026 and 2027 gave ${days} days, expected 730`);
if (!mondayTrouble) ok(`every one of ${days} days sits in a week that starts on a Monday`);

// The clock changes, named rather than left to the loop above to happen to
// cover: these are the two weeks a local-time calculation gets wrong.
for (const change of ["2026-03-08", "2026-11-01", "2027-03-14", "2027-11-07"]) {
  const before = addDays(change, -1);
  const after = addDays(change, 1);
  if (addDays(before, 1) !== change || addDays(change, 1) !== after) {
    fail(`a day either side of the clock change on ${change} does not add up`);
  }
  if (mondayOf(change) !== mondayOf(addDays(change, 0))) {
    fail(`the week of ${change} depends on how it is asked`);
  }
}
if (!problems.length) ok("the weeks of the four clock changes in 2026 and 2027 add up");

// ── 2. a month is made of its weeks, and all of them ──────────

let months = 0;
for (const m of everyMonth("2026-01-01", "2027-12-01")) {
  months++;
  const from = m;
  const to = monthEndOf(m);
  const weeks = weeksAcross(from, to);

  // Every day of the month is in exactly one of them.
  const seen = new Map();
  for (const week of weeks) {
    for (let i = 0; i < 7; i++) {
      const day = addDays(week, i);
      if (day < from || day > to) continue;
      seen.set(day, (seen.get(day) ?? 0) + 1);
    }
  }
  for (const d of everyDay(from, to)) {
    const n = seen.get(d) ?? 0;
    if (n !== 1) fail(`${d} is in ${n} of the weeks ${from} is assembled from, expected 1`);
  }
  if (weeks[0] > from) fail(`${from} starts before the first week of its own month`);
  if (addDays(weeks[weeks.length - 1], 6) < to) fail(`${to} is after the last week of its own month`);
  if (weeks.some((w) => isoDay(w) !== 1)) fail(`a week of ${from} does not start on a Monday`);
}
if (months !== 24) fail(`stepping a month at a time gave ${months} months, expected 24`);
if (!problems.length) ok(`every day of all ${months} months belongs to exactly one of its weeks`);

// ── 3. and the dates they are due ─────────────────────────────

for (const m of everyMonth("2026-01-01", "2027-12-01")) {
  const due = monthlyDueOn(m);
  const next = monthStartOf(addDays(monthEndOf(m), 1));
  if (due !== addDays(next, 4)) fail(`${m} is due ${due}, not the 5th of ${next.slice(0, 7)}`);
  if (previousMonthOf(next) !== m) fail(`the month before ${next} is not ${m}`);
}
for (const w of everyWeek("2026-01-05", "2027-12-27")) {
  const due = weeklyDueOn(w);
  if (isoDay(due) !== 3) fail(`the week of ${w} is due ${due}, which is not a Wednesday`);
  if (due !== addDays(addDays(w, 6), 3)) fail(`the week of ${w} is due before its own Sunday`);
  if (lastWeekOf(addDays(w, 7)) !== w) fail(`the week before the one after ${w} is not ${w}`);
}
if (!problems.length) ok("a week is due the Wednesday after it ends and a month the 5th after it");

// ── 4. a held-back note's words stay held back ────────────────

const period = src("lib/report-period.ts");

if (!/REPORT_ROLES = \["Admin", "Job Search", "Reports", "Billing"\]/.test(period)) {
  fail("REPORT_ROLES is no longer the four roles an ordinary note is visible to");
}
if (!/REPORT_ROLES\.every\(/.test(period)) {
  fail("the note gate no longer asks whether a note covers every one of REPORT_ROLES");
}

// One place puts a note's words into a report, and it is behind the gate.
const uses = [...period.matchAll(/n\.text/g)];
if (uses.length !== 1) {
  fail(`a note's words are read in ${uses.length} places in lib/report-period.ts, expected 1`);
} else {
  const before = period.slice(Math.max(0, uses[0].index - 300), uses[0].index);
  if (!/open\s*\n?\s*\?/.test(before)) {
    fail("a note's words are used without the visibility gate in front of them");
  } else {
    ok("the one place a note's words reach a report is behind the gate");
  }
}

// ── 5. something actually drafts them ────────────────────────

const route = src("app/api/cron/reports/route.ts");
if (!/process\.env\.CRON_SECRET/.test(route) || !/status: 401/.test(route)) {
  fail("the reports route does not refuse a request without the scheduler's secret");
}
// The day is read in the practice's zone. `new Date()` on Vercel is UTC, and a
// job that runs at 06:00 Mountain runs on the previous UTC day for six hours
// of the year - which is how a Monday job would miss its Monday.
if (!/\btoday\(\)/.test(route)) {
  fail("the reports route does not read the day in the practice's own timezone");
}
if (!/getUTCDay\(\) === 1/.test(route) || !/endsWith\("-01"\)/.test(route)) {
  fail("the reports route no longer decides for itself whether it is Monday or the 1st");
}

const migrations = readdirSync(new URL("../supabase/migrations/", import.meta.url));
const scheduling = migrations
  .map((name) => [name, src(`supabase/migrations/${name}`)])
  .filter(([, text]) => /cron\.schedule\(\s*'zion-reports'/.test(text));
if (scheduling.length !== 1) {
  fail(`${scheduling.length} migrations schedule zion-reports, expected 1`);
} else {
  const [name, text] = scheduling[0];
  const when = /cron\.schedule\(\s*'zion-reports',\s*'([^']+)'/.exec(text)?.[1] ?? "";
  const fields = when.split(/\s+/);
  if (fields.length !== 5) {
    fail(`${name} schedules zion-reports as "${when}", which is not five fields`);
  } else if (fields[2] !== "*" || fields[4] !== "*") {
    // Daily, so the route decides the day. A job pinned to a UTC day of the
    // month drafts twice or not at all in the weeks the clock moves.
    fail(`${name} pins zion-reports to a day ("${when}") instead of running it daily`);
  } else {
    ok(`zion-reports is scheduled daily by ${name}, and the route decides the day`);
  }
}

// ── 6. what reaches a counselor ───────────────────────────────

/**
 * A month with one authorized service nothing happened under, one that things
 * did happen under, two notes held back, and a stretch nobody kept a week
 * for. Every property asserted below is a property of a real report, so the
 * content is built to have all of them at once.
 */
const content = {
  from: "2026-10-01",
  to: "2026-10-31",
  hours: 4.5,
  withheld: 2,
  sections: [
    { service: "WSA Tier 2", code: "A-1", lines: [] },
    {
      service: "Job Coaching",
      code: "B-2",
      lines: [
        { on: "2026-10-06", kind: "hours", text: "Job coaching", hours: 4.5 },
        { on: "2026-10-08", kind: "note", text: "Progress — note held back, on the client record" },
        { on: "2026-10-14", kind: "job", text: "Applied to ZQ Warehousing" },
      ],
    },
    // Placed in a month this report does not cover, which is the case the
    // standing line exists for: everything else in a section is dated inside
    // the period, so a counselor reading October about a September hire was
    // being told nothing about the hire at all.
    {
      service: "Job Placement",
      code: "C-3",
      lines: [
        {
          on: "2026-10-31",
          standing: true,
          kind: "placement",
          text: "Placed Sep 3, 2026 — ZQ Warehousing — Clerk. 30-day check Oct 3, 2026",
        },
      ],
    },
  ],
  weeks: [
    { week_start: "2026-09-28", status: "Confirmed", note: "ZZ settled into the shift." },
    { week_start: "2026-10-05", status: "Draft", note: "ZZ not written up yet." },
  ],
  gaps: [{ from: "2026-10-12", to: "2026-10-18" }],
};
const meta = {
  clientName: "ZZ Reportperson",
  clientNo: 4242,
  agencyId: "V0000",
  counselorName: "ZQ Dana Counselor",
  ownerName: "ZQ Owner",
  summary: "",
};

const report = monthlyReportLines("2026-10-01", content, meta);
const whole = report.map((l) => `${l.on ?? ""} ${l.text}`).join("\n");

// A service the client holds says so even with nothing under it. This is the
// sentence the brief asks for, and the one that makes a month of no service
// visible to the counselor instead of absent from the report.
const tier = report.findIndex((l) => l.as === "label" && l.text.startsWith("WSA Tier 2"));
if (tier < 0) {
  fail("a service the client is authorized for is not a section of the report");
} else if (report[tier + 1]?.text !== "No activity recorded.") {
  fail(`an authorized service with nothing under it says "${report[tier + 1]?.text}"`);
} else {
  ok("a service with no activity says so rather than being left out");
}

// The held-back notes are counted and never quoted. The line the builder left
// behind carries the type and the date and no words, and the count has to
// reach the page or nobody knows anything was left out.
if (!/2 notes on this client.s record are not included here/.test(whole)) {
  fail("the report does not say that notes were held back");
} else if (!/note held back/.test(whole)) {
  fail("the held-back note lost its line as well as its words");
} else {
  ok("held-back notes are counted on the report and not quoted");
}

// The stretch nobody kept a week for is owned, as a count and not as dates: a
// counselor needs to know what the account rests on, not which Monday
// somebody here missed.
if (!/1 stretch of the month taken from the record/.test(whole)) {
  fail("the report does not say part of the month had no weekly account");
}

// A confirmed week's own sentence is the one thing in the report nobody read
// off the record, so it has to be in it. An unconfirmed week's is not: it has
// not been stood behind by the person who did the work.
if (!whole.includes("ZZ settled into the shift.")) {
  fail("a confirmed week's own words are not in the report");
} else if (whole.includes("ZZ not written up yet.")) {
  fail("an unconfirmed week's words are in the report the practice signs");
} else {
  ok("a confirmed week's words are in the report and an unconfirmed week's are not");
}

// The drafted summary is offered, not imposed, and five lines is the cap.
const drafted = draftMonthlySummary(content);
if (drafted.split("\n").length > MOST_SUMMARY_LINES) {
  fail(`the drafted summary is ${drafted.split("\n").length} lines, and the cap is ${MOST_SUMMARY_LINES}`);
}
// The cap is asserted where it lives as well as where content reaches it.
// The summary is made of five kinds of line, so no content can produce a
// sixth and no fixture can tell whether the cap is still there - which is
// how this check first passed with the cap taken out.
if (MOST_SUMMARY_LINES !== 5) {
  fail(`the summary cap is ${MOST_SUMMARY_LINES} lines, and the brief says five`);
}
if (!/lines\.slice\(0, MOST_SUMMARY_LINES\)/.test(src("lib/report-text.ts"))) {
  fail("the drafted summary is no longer capped where the cap lives");
}
if (!/4\.5 hours/.test(drafted)) {
  fail(`the drafted summary does not count the hours: "${drafted}"`);
}
const own = monthlyReportLines("2026-10-01", content, { ...meta, summary: "ZZ own words." });
if (!own.some((l) => l.text === "ZZ own words.")) {
  fail("a summary somebody wrote is not what the report carries");
} else if (own.some((l) => l.text === drafted.split("\n")[0])) {
  fail("the drafted summary is still in the report after somebody wrote their own");
} else {
  ok("the summary is drafted from counted facts and replaced by whoever signs");
}

// A month with nothing in it says so. The whole feature exists because
// counselors were not being told, and a blank report would be the old silence
// with a letterhead on it.
const nothing = monthlyReportLines(
  "2026-10-01",
  { from: "2026-10-01", to: "2026-10-31", hours: 0, withheld: 0, sections: [], weeks: [], gaps: [] },
  meta,
);
if (!nothing.some((l) => l.text === "No service hours were logged this month.")) {
  fail("a month with no service hours does not say so");
} else if (!nothing.some((l) => l.text === "No service was authorized for this month.")) {
  fail("a month with no authorized service does not say so");
} else {
  ok("a month with nothing in it says so rather than going out blank");
}

// ── 7. one renderer, and one way to send it ──────────────────

// The screen somebody signs on and the PDF they sign both draw the same
// array. A screen laying the sections out itself is a second renderer, and
// the day the two disagree the practice has signed something it did not read.
let twoRenderers = 0;
for (const [file, what] of [
  ["app/(app)/clients/[id]/reports/[month]/page.tsx", "the month screen"],
  ["lib/report-pdf.ts", "the report PDF"],
]) {
  const text = src(file);
  if (!/monthlyReportLines/.test(text)) {
    twoRenderers++;
    fail(`${what} does not draw the one renderer`);
  } else if (/\.sections\s*\??\.?\s*map\(/.test(text)) {
    twoRenderers++;
    fail(`${what} lays the sections out itself as well as drawing the renderer`);
  }
}
if (!twoRenderers) ok("the screen and the PDF draw the same report");

// Nothing is sent unsigned, and what goes is the PDF that was signed.
const filing = src("lib/mail-filing.ts");
if (!/status !== "Signed"/.test(filing)) {
  fail("the send does not refuse a report that has not been signed");
}
if (!/documents\.includes\(row\.pdf_attachment_id\)/.test(filing)) {
  fail("the send does not check that the attached document is the PDF that was signed");
}

// And it is marked sent after it has gone, not before.
const mailAction = src("app/(app)/mail/actions.ts");
const went = mailAction.indexOf("sendNewAndReport(");
const marked = mailAction.indexOf("markReportSent(");
if (went < 0 || marked < 0) {
  fail("the send no longer marks the monthly report sent");
} else if (marked < went) {
  fail("the report is marked sent before the message has gone");
} else {
  ok("a report goes only signed, only as the PDF it was signed as, and is marked after it goes");
}

// ── where a placement stands ─────────────────────────────────
//
// The hire is in a month this report does not cover, so every assertion here
// is about the one line that is allowed to reach outside the period.
{
  const at = report.findIndex((l) => l.as === "label" && l.text.startsWith("Job Placement"));
  const line = report[at + 1];

  if (at < 0) {
    fail("an authorized Job Placement is not a section of the report");
  } else if (!line || !/Placed Sep 3, 2026/.test(line.text)) {
    fail(`the placement section opens with "${line?.text}" rather than when the client was placed`);
  } else if (line.as !== "text" || line.on) {
    // Dated at the end of the period so the month can slice on it. Printing
    // that date would tell a counselor the client was hired on 31 October.
    fail(`the standing line is drawn as a dated entry (${line.as}, on=${line.on})`);
  } else if (!/30-day check Oct 3, 2026/.test(line.text)) {
    fail("the standing line does not carry the retention checks the record holds");
  } else {
    ok("a placement says when it started and which checks are recorded, whatever month the report covers");
  }

  // A section with a placement and nothing else this month has already said
  // something, so it must not also claim there was no activity.
  const after = report[at + 2];
  if (/No activity recorded/.test(after?.text ?? "")) {
    fail("a section with a placement in it also says no activity was recorded");
  } else if (!/Nothing further recorded this month/.test(after?.text ?? "")) {
    fail(`a placement section with no events this month says "${after?.text}"`);
  } else {
    ok("a placement with nothing done this month says so without contradicting itself");
  }

  // And the drafted summary names the placement rather than counting it.
  const drafted = draftMonthlySummary(content);
  if (!/Placed Sep 3, 2026/.test(drafted)) {
    fail("the drafted summary does not mention the placement");
  } else if ((drafted.match(/Placed Sep 3, 2026/g) ?? []).length !== 1) {
    fail("the drafted summary names the hire date more than once");
  } else {
    ok("the drafted summary names the placement once");
  }
}

// ── the category list is one list ────────────────────────────
//
// The screens offer `NOTE_CATEGORIES` and the database enforces the check
// constraint in 0266. A category one of them knows and the other does not is a
// note somebody loses on save, so the two are read against each other rather
// than kept in step by hand.
{
  // The latest migration that declares the constraint, not a named one. The
  // first version of this read 0266 by name and failed the moment 0269 added
  // an eighth category - which is the check telling the truth about the wrong
  // question. Ask which migration declares the rule now.
  const declaring = readdirSync(new URL("../supabase/migrations", import.meta.url))
    .filter((f) => /\.sql$/.test(f))
    .sort()
    .filter((f) => /notes_category_check\s+check/.test(src(`supabase/migrations/${f}`)));
  const migration = declaring.length ? src(`supabase/migrations/${declaring.at(-1)}`) : "";

  if (!migration) {
    fail("no migration declares the note categories, so nothing says what the database allows");
  } else {
    const declared = [...migration.matchAll(/^\s*'([A-Z][a-z]+(?: [a-z]+)*)',?\s*$/gm)].map((m) => m[1]);
    const missing = NOTE_CATEGORIES.filter((c) => !declared.includes(c));
    const extra = declared.filter((c) => !NOTE_CATEGORIES.includes(c));
    if (missing.length) {
      fail(`the screens offer categories the database refuses: ${missing.join(", ")}`);
    } else if (extra.length) {
      fail(`the database allows categories no screen offers: ${extra.join(", ")}`);
    } else {
      ok(`the ${NOTE_CATEGORIES.length} note categories are the same list on both sides`);
    }
  }

  // The map has to agree with category_for_stage in the same migration, for
  // the same reason: the screen guesses with one and the backfill with the
  // other, and a disagreement puts a note in a section nobody expected.
  const pairs = [
    ["Job Development", "Job development"],
    ["Job Placement", "Job placement"],
    ["Job Coaching", "Job coaching"],
    ["Job Search", "Job search"],
    ["Assessment", "Assessment"],
    ["Life Skills", "Life skills"],
    ["Intake", "General progress"],
  ];
  const wrong = pairs.filter(([stage, want]) => categoryForStage(stage) !== want);
  if (wrong.length) {
    fail(`the stage map disagrees with the database for: ${wrong.map(([s]) => s).join(", ")}`);
  } else if (categoryForStage("something nobody has added yet") !== "General progress") {
    fail("a stage the map does not know falls somewhere other than General progress");
  } else {
    ok("a stage implies the same category in the screens as in the database");
  }
}

// ── Personal never reaches a counselor ───────────────────────
//
// Two guards, asserted separately, because this is the one category whose
// whole purpose is not being in a report. The first is the filter; the second
// is that it is not counted as withheld either - "two notes are not included
// here" about somebody's housing is still telling a counselor something.
{
  const period = src("lib/report-period.ts");
  if (!/isPersonal\(n\.category\)\)\s*continue/.test(period)) {
    fail("the monthly report does not drop a Personal note before anything else");
  } else if (period.indexOf("isPersonal(n.category)") > period.indexOf("if (!open) withheld++")) {
    fail("a Personal note is counted as withheld before it is dropped");
  } else {
    ok("a Personal note is out of the monthly report and is not counted as held back");
  }

  if (!/category !== "Personal"/.test(src("lib/report.ts"))) {
    fail("the on-demand report does not drop Personal notes");
  } else if (!/neq\("category", PERSONAL\)/.test(src("lib/form-autofill.ts"))) {
    fail("USOR 96 is filled from notes without dropping Personal");
  } else {
    ok("the on-demand report and USOR 96 drop Personal as well");
  }

  // And the category list itself has not quietly lost it.
  if (!NOTE_CATEGORIES.includes(PERSONAL)) {
    fail("Personal is no longer one of the categories, so nothing can be marked as it");
  }
}

// ── a note is asked what it is about ─────────────────────────
//
// The rule is run rather than read. The first version of this matched
// `NOTE_CATEGORIES.includes(...)` in the action's source and passed with
// `false &&` written in front of it, which is the fault CLAUDE.md warns about
// and which this check was written to catch in the first place.
{
  const refused = [
    ["nothing at all", ""],
    ["whitespace", "   "],
    ["a category nobody declared", "Housing"],
    ["the wrong case", "job coaching"],
    ["something that is not a string", null],
  ].filter(([, value]) => noteCategoryFromForm(value) !== null);

  const accepted = NOTE_CATEGORIES.filter((c) => noteCategoryFromForm(c) !== c);

  if (refused.length) {
    fail(`a note category was accepted off a form when it should not be: ${refused.map(([w]) => w).join(", ")}`);
  } else if (accepted.length) {
    fail(`a declared category was refused off a form: ${accepted.join(", ")}`);
  } else {
    ok(`a category off a form is one of the ${NOTE_CATEGORIES.length} or it is nothing`);
  }

  // And the only way one reaches the insert is through that function: the raw
  // form value is not read anywhere in the action, so there is no second path
  // for a guard to be taken off the front of.
  const noteAction = src("app/(app)/clients/[id]/actions.ts");
  if (/formData\.get\("category"\)\s*\)?\s*(?:\?\?|\|\||as |\))/.test(noteAction.replace(/noteCategoryFromForm\(formData\.get\("category"\)\)/g, "")) ||
      /String\(formData\.get\("category"\)/.test(noteAction)) {
    fail("the note action reads the category off the form without putting it through the rule");
  } else if (!/noteCategoryFromForm\(formData\.get\("category"\)\)/.test(noteAction)) {
    fail("the note action does not put the category through the rule at all");
  } else if (!/if \(!category\) return \{ error:/.test(noteAction)) {
    fail("the note action does not stop when the category comes back as nothing");
  } else if (!/name="category"/.test(src("app/(app)/clients/[id]/notes-tab.tsx"))) {
    fail("the note form does not ask which service it is about");
  } else {
    ok("a note is refused unless it says which service it is about");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- REPORTS VERIFIED ---");
