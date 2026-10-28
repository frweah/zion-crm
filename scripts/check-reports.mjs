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

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- REPORTS VERIFIED ---");
