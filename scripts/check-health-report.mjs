/**
 * What the Monday health email says, over made-up figures (0278).
 *
 *   node scripts/check-health-report.mjs
 *
 * The email exists to be believed on a Monday morning, and the way it fails is
 * not by erroring: it is by reading as reassuring when it has nothing to be
 * reassuring about. "The suite passes" is not a claim this system can make.
 * So the words are run here rather than read, which is why `lib/health-report`
 * has no imports - the same split as `lib/report-shape.ts`.
 */
import { healthEmail, verifyLine, backupLine, graphLine, daysSince } from "../lib/health-report.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const nothing = {
  verify_at: null,
  verify_ok: null,
  verify_detail: null,
  backup_at: null,
  backup_ok: null,
  backup_detail: null,
  graph_total: 4,
  graph_expiring: 0,
  graph_soonest: "2026-11-02T06:45:09Z",
  graph_failing: 0,
  stale_count: 0,
  billing_over_90: 0,
  billing_over_90_amount: 0,
  billing_oldest: null,
  reports_due: 0,
  reports_sent: 0,
  reports_overdue: 0,
  reports_oldest_unsent: null,
};
const now = new Date("2026-11-02T14:00:00Z");
const clear = {
  ...nothing,
  verify_at: "2026-11-01T18:00:00Z",
  verify_ok: true,
  verify_detail: "all 126 scripts passed",
  backup_at: "2026-11-01T18:00:00Z",
  backup_ok: true,
  backup_detail: "fingerprint abc123",
};

// ── never run never reads as passing ─────────────────────────
if (!/never run/.test(verifyLine(nothing, now))) {
  fail("a suite that has never been run does not say so");
} else if (/passed/.test(verifyLine(nothing, now))) {
  fail("a suite that has never been run reads as passed");
} else if (!/never taken/.test(backupLine(nothing, now))) {
  fail("a fingerprint that has never been taken does not say so");
} else if (/all clear/.test(healthEmail(nothing, "2026-11-02", now).subject)) {
  // Not a phrase: the subject names one thing and counts several, so what
  // matters is that it is not calling the week clear.
  fail("a week where nothing has been run says all clear");
} else {
  ok("what has never been run says so, and is in the subject");
}

// ── and it says how to do it ─────────────────────────────────
// A line that says a thing has not been done and not how to do it is a line
// somebody has to go and look something up for.
if (!/verify-all\.mjs/.test(verifyLine(nothing, now))) {
  fail("the line about an unrun suite does not say the command");
} else if (!/backup-fingerprint\.mjs/.test(backupLine(nothing, now))) {
  fail("the line about an untaken fingerprint does not say the command");
} else {
  ok("and each says the command that would do it");
}

// ── a failure is loud ────────────────────────────────────────
const failing = { ...clear, verify_ok: false, verify_detail: "2 of 126 failed" };
if (!/FAILING/.test(verifyLine(failing, now))) {
  fail("a failing suite does not say it is failing");
} else if (!/failing/.test(healthEmail(failing, "2026-11-02", now).subject.toLowerCase())) {
  fail("a failing suite is not in the subject");
} else {
  ok("a failing suite is in the line and in the subject");
}

// ── all clear only when everything is ────────────────────────
if (!/all clear/.test(healthEmail(clear, "2026-11-02", now).subject)) {
  fail("a week with nothing wrong does not say all clear");
} else {
  const checks = [
    ["an old passing suite", { ...clear, verify_at: "2026-10-20T18:00:00Z" }],
    ["a failed restore check", { ...clear, backup_ok: false }],
    // Only the fingerprint unknown, so the suite is not answering for it: the
    // first version of this had both unrun and could not tell which was
    // keeping the subject from saying all clear.
    ["no fingerprint ever taken", { ...clear, backup_at: null, backup_ok: null, backup_detail: null }],
    ["a fingerprint over a month old", { ...clear, backup_at: "2026-09-20T18:00:00Z" }],
    ["no mailbox connected", { ...clear, graph_total: 0 }],
    ["a subscription about to lapse", { ...clear, graph_expiring: 1 }],
    ["money over 90 days old", { ...clear, billing_over_90: 1 }],
    ["an overdue report", { ...clear, reports_overdue: 1 }],
  ];
  const quiet = checks.filter(([, h]) => /all clear/.test(healthEmail(h, "2026-11-02", now).subject));
  if (quiet.length) {
    fail(`${quiet.map(([what]) => what).join(", ")} still says all clear`);
  } else {
    ok(`all clear only when it is, and ${checks.length} kinds of trouble each reach the subject`);
  }
}

// A full Stale view is not an alarm: it is a list to close when somebody has
// an afternoon, and an email that shouted about it every week would be an
// email nobody reads.
if (!/all clear/.test(healthEmail({ ...clear, stale_count: 40 }, "2026-11-02", now).subject)) {
  fail("a full Stale view raises an alarm, and it is a list rather than an alarm");
} else {
  ok("and a full Stale view is reported without being an alarm");
}

// ── one item per thing ───────────────────────────────────────
const old = { ...clear, verify_at: "2026-10-20T18:00:00Z", verify_ok: false, verify_detail: "1 failed" };
const mentions = (healthEmail(old, "2026-11-02", now).body.match(/verify suite/g) ?? []).length;
if (mentions > 1) {
  fail("a suite that is failing and old is listed twice, which makes the list read as longer than it is");
} else {
  ok("a suite that is both failing and old is one thing to look at");
}

// ── the age is right ─────────────────────────────────────────
// Not a whole number of days apart, on purpose: a gap of exactly four days
// reads as four whether the arithmetic rounds down or up, so the first
// version of this could not tell Math.floor from Math.ceil.
if (daysSince("2026-10-29T06:00:00Z", now) !== 4) {
  fail(`four and a bit days ago is read as ${daysSince("2026-10-29T06:00:00Z", now)} days`);
} else if (daysSince(null, now) !== null) {
  fail("the age of something that never happened is a number");
} else if (!/yesterday/.test(verifyLine({ ...clear, verify_at: "2026-11-01T14:00:00Z" }, now))) {
  fail("yesterday is not called yesterday");
} else {
  ok("an age is counted in whole days, and yesterday is called yesterday");
}

// ── no mailbox is said plainly ───────────────────────────────
if (!/nothing is arriving/.test(graphLine({ ...clear, graph_total: 0 }))) {
  fail("no mailbox subscription is not reported as nothing arriving");
} else {
  ok("no mailbox subscription says that nothing is arriving by itself");
}

// ── nothing in it is a person ────────────────────────────────
// Counts, dates and a fingerprint. The email is read on a phone and may be
// forwarded; a client's name in it would be a disclosure nobody decided on.
const body = healthEmail({ ...clear, billing_over_90: 2, billing_over_90_amount: 4180, billing_oldest: "2026-06-02", reports_due: 3, reports_oldest_unsent: "2026-08-01" }, "2026-11-02", now).body;
if (/\b(client|counselor|staff)\b/i.test(body)) {
  fail("the email names a client, a counselor or a member of staff");
} else {
  ok("the email carries counts, dates and a fingerprint, and nobody's name");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- HEALTH REPORT VERIFIED ---");
