/**
 * The progress report presets, checked.
 *
 *   node --experimental-strip-types scripts/check-report.mjs
 *
 * A preset decides what a counselor is told. The failures worth catching are
 * quiet ones: a preset that drops the summary, a job development update that
 * carries the invoice table into a counselor's inbox, or a bad ?preset= in a
 * URL producing an empty report rather than falling back to the full one.
 *
 * It also reads lib/report.ts to check the builder still asks only for
 * columns a counselor may see. The report is the one thing in this system that
 * leaves the building by email, and Admin can read restricted fields — so an
 * innocent-looking join to client_private would put a date of birth in an
 * email and nothing else would stop it.
 */
import { readFile } from "node:fs/promises";
import { REPORT_PRESETS, presetByKey } from "../lib/report-presets.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

// ── the four the brief asks for ──────────────────────────────
const keys = REPORT_PRESETS.map((p) => p.key);
if (keys.length !== 4) fail(`there are ${keys.length} presets, not 4`);
else ok("four reports are offered");

if (new Set(keys).size !== keys.length) fail("two presets share a key");
else ok("each has its own key, so a link means one thing");

// ── every report says who it is about and what happens next ──
for (const p of REPORT_PRESETS) {
  if (!p.sections.includes("summary")) fail(`${p.label} has no summary`);
  if (!p.sections.includes("next")) fail(`${p.label} does not ask for next steps`);
  if (p.sections.length < 3) fail(`${p.label} includes almost nothing`);
  if (new Set(p.sections).size !== p.sections.length) {
    fail(`${p.label} lists a section twice, which would print it twice`);
  }
}
if (!problems.length) {
  ok("every report carries a summary and next steps, and no section twice");
}

// ── general progress is the one that goes with an invoice ────
const general = presetByKey("general");
for (const p of REPORT_PRESETS) {
  for (const s of p.sections) {
    if (!general.sections.includes(s)) {
      fail(`${p.label} includes "${s}", which general progress does not`);
    }
  }
}
ok("general progress is a superset — no update says more than the full report");

// ── billing detail is not an update, it is an invoice ────────
const withBilling = REPORT_PRESETS.filter((p) => p.sections.includes("billing")).map(
  (p) => p.key,
);
if (withBilling.join(",") !== "general") {
  fail(`the billing table appears in: ${withBilling.join(", ") || "nothing"}`);
} else {
  ok("only the full report carries the billing table");
}

// ── a junk preset in a URL falls back rather than empties ────
for (const junk of ["", null, undefined, "coaching-update", "../etc", "GENERAL"]) {
  if (presetByKey(junk).key !== "general") {
    fail(`presetByKey(${JSON.stringify(junk)}) did not fall back to general progress`);
  }
}
ok("an unrecognised ?preset= falls back to the full report, never to an empty one");

// ── nothing restricted goes out by email ─────────────────────
const source = await readFile(new URL("../lib/report.ts", import.meta.url), "utf8");
// ORG.address is the practice's own letterhead, which belongs on a report.
const body = source.replace(/\bORG\.\w+/g, "");
const forbidden = ["client_private", "dob", "address", "accommodation", "ssn", "tin"];
const found = forbidden.filter((t) => new RegExp(`\\b${t}\\b`, "i").test(body));
if (found.length) {
  fail(
    `lib/report.ts mentions ${found.join(", ")} — a report is emailed outside the practice, ` +
      `and Admin can read restricted fields, so check this by hand before shipping it`,
  );
} else {
  ok("the builder asks for no restricted field, so no report can carry one");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- PROGRESS REPORT PRESETS VERIFIED ---");
