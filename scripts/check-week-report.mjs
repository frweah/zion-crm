/**
 * What the Friday email says about somebody's week, over made-up figures.
 *
 *   node scripts/check-week-report.mjs
 *
 * The Monday health email is checked this way (0278) because the way it fails
 * is not by erroring - it is by reading as reassuring when it has nothing to
 * be reassuring about. The week email fails the same way and one worse: it
 * goes to five different people about themselves, so a line that reads
 * cheerfully over five zeros teaches somebody to stop opening it, and a line
 * that names a client is a disclosure sitting in an inbox.
 *
 * So the words are run here rather than read, which is why `lib/week-report`
 * has no imports.
 */
import { weekEmail, didLine, waitingLine, aheadLine, span } from "../lib/week-report.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const empty = {
  staff_name: "Ida Nobody",
  email: "ida@example.test",
  role: "Billing",
  week_start: "2026-11-02",
  week_end: "2026-11-06",
  billable_hours: 0,
  clocked_hours: 0,
  notes_written: 0,
  contacts_logged: 0,
  tasks_done: 0,
  tasks_open: 0,
  tasks_overdue: 0,
  clients_carried: 0,
  appointments: 0,
};

const busy = {
  ...empty,
  staff_name: "Rhoda Busy",
  role: "Job Search",
  billable_hours: 12.5,
  clocked_hours: 36,
  notes_written: 9,
  contacts_logged: 18,
  tasks_done: 17,
  tasks_open: 13,
  tasks_overdue: 8,
  clients_carried: 14,
  appointments: 3,
};

// ── a week with nothing in it says so ───────────────────────
if (!/Nothing is recorded against you/.test(didLine(empty))) {
  fail(`a week with nothing in it reads as "${didLine(empty)}"`);
} else if (/0 /.test(didLine(empty))) {
  fail("a week with nothing in it lists its zeros");
} else {
  ok("a week with nothing recorded says that, rather than listing five zeros");
}

// ── and one with something in it leaves out what is zero ────
const did = didLine({ ...empty, clocked_hours: 8, notes_written: 2 });
if (/billable|call|finished/.test(did)) {
  fail(`a part that is zero is still in the line: "${did}"`);
} else if (!/8 hours on the clock/.test(did) || !/2 notes/.test(did)) {
  fail(`what happened is not in the line: "${did}"`);
} else {
  ok("what did not happen is left out, and what did is named with its number");
}

// ── one hour is an hour ─────────────────────────────────────
if (!/1 hour on the clock/.test(didLine({ ...empty, clocked_hours: 1 }))) {
  fail(`one hour reads as "${didLine({ ...empty, clocked_hours: 1 })}"`);
} else if (!/1 note\b/.test(didLine({ ...empty, notes_written: 1 }))) {
  fail(`one note reads as "${didLine({ ...empty, notes_written: 1 })}"`);
} else {
  ok("one of a thing is singular, in the hours and in the counts");
}

// ── what is waiting is never hidden ─────────────────────────
if (!/Nothing is waiting on you/.test(waitingLine(empty))) {
  fail(`an empty list reads as "${waitingLine(empty)}"`);
} else if (!/8 of them past their date/.test(waitingLine(busy))) {
  fail(`overdue tasks are not named: "${waitingLine(busy)}"`);
} else if (!/none past its date/.test(waitingLine({ ...busy, tasks_overdue: 0 }))) {
  fail(`open tasks with none overdue reads as "${waitingLine({ ...busy, tasks_overdue: 0 })}"`);
} else {
  ok("what is waiting says how much of it is late, and an empty list says so plainly");
}

// ── the subject carries the late thing ──────────────────────
const late = weekEmail(busy, "2026-11-06");
const clear = weekEmail(empty, "2026-11-06");
if (!/8 tasks past their date/.test(late.subject)) {
  fail(`the subject does not carry what is late: "${late.subject}"`);
} else if (!/nothing past its date/.test(clear.subject)) {
  fail(`a clear week's subject reads as "${clear.subject}"`);
} else if (late.subject === clear.subject) {
  fail("every week has the same subject");
} else {
  ok("the subject says what is late, or that nothing is");
}

// ── the week it is about ────────────────────────────────────
if (span("2026-11-02", "2026-11-06") !== "2 to 6 Nov") {
  fail(`a week inside one month reads as "${span("2026-11-02", "2026-11-06")}"`);
} else if (span("2026-10-26", "2026-11-06") !== "26 Oct to 6 Nov") {
  fail(`a week across two months reads as "${span("2026-10-26", "2026-11-06")}"`);
} else {
  ok("the email says which days it is about, in both halves of a month");
}

// ── and it names nobody but the person reading it ───────────
//
// Every figure the email can hold, made absurd, and the body searched for
// anything that is not a number, a date, the reader's own name or one of the
// words these lines are built from. The failure this guards is somebody later
// adding "your busiest client" to the summary: useful, and a client's name in
// an inbox on a phone on a bus.
const everything = {
  ...busy,
  staff_name: "Rhoda Busy",
};
const { body } = weekEmail(everything, "2026-11-06");
const WORDS = new Set(
  (
    "rhoda busy your week of to nov this on the clock billable notes calls logged tasks " +
    "finished waiting you of them past their date next in diary and client clients " +
    "appointment appointments nothing is recorded against none its hours hour note call task list"
  ).split(/\s+/),
);
const strange = body
  .toLowerCase()
  .replace(/[.,:—-]/g, " ")
  .split(/\s+/)
  .filter(Boolean)
  .filter((w) => !WORDS.has(w) && !/^[\d.]+$/.test(w));
if (strange.length) {
  fail(`the week email says words this check does not know: ${[...new Set(strange)].join(", ")}`);
} else {
  ok("the email is counts, dates and the reader's own name, and nothing else");
}

// ── is this check checking anything ─────────────────────────
if (didLine(empty) === didLine(busy)) {
  fail("didLine says the same thing about an empty week and a full one, so this checks nothing");
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s) with the week email:`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- THE WEEK EMAIL VERIFIED ---\n");
