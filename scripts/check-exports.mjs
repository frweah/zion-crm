/**
 * The monthly export, checked.
 *
 *   node --experimental-strip-types scripts/check-exports.mjs
 *
 * An export is the one thing in this system that produces a file with no
 * roles attached to it. Inside the app a date of birth is restricted to three
 * roles by row-level security; in a CSV on somebody's laptop it is restricted
 * to nobody. So the rule is that restricted columns are never exported at all,
 * not even to Admin, and this is what holds that rule down.
 *
 * The second failure it guards against is duller and likelier: a download link
 * on the page with no handler behind it, found at month end by an accountant.
 */
import { readFile } from "node:fs/promises";
import { EXPORTS, RESTRICTED_COLUMNS, exportsFor, toCsv, csvCell, monthRange } from "../lib/exports.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const route = await readFile(
  new URL("../app/api/export/[kind]/route.ts", import.meta.url),
  "utf8",
);

// ── every offered kind is handled ────────────────────────────
for (const kind of EXPORTS) {
  if (!route.includes(`kind === "${kind.key}"`)) {
    fail(`"${kind.key}" is offered on the page and has no handler`);
  }
}
if (!problems.length) ok(`all ${EXPORTS.length} exports have a handler behind them`);

// ── and nothing is handled that is not offered ───────────────
const handled = [...route.matchAll(/kind === "([a-z-]+)"/g)].map((m) => m[1]);
const offered = EXPORTS.map((e) => e.key);
const extra = handled.filter((h) => !offered.includes(h));
if (extra.length) {
  fail(`the route serves ${extra.join(", ")}, which nothing offers — an unlisted export`);
} else {
  ok("and nothing is served that the page does not list");
}

// ── nothing restricted leaves the building ───────────────────
// Read the select lists, not the whole file: the comments talk about dates of
// birth on purpose.
const selects = [...route.matchAll(/\.select\(\s*("(?:[^"\\]|\\.)*"|`[^`]*`)/g)].map((m) => m[1]);
if (selects.length === 0) fail("no select lists found in the route — has it been rewritten?");

const leaked = [];
for (const list of selects) {
  for (const bad of RESTRICTED_COLUMNS) {
    if (new RegExp(`\\b${bad}\\b`).test(list)) leaked.push(`${bad} in ${list.slice(0, 60)}…`);
  }
}
if (leaked.length) {
  fail(`a restricted column is being exported: ${leaked.join("; ")}`);
} else {
  ok(`no select list mentions any of the ${RESTRICTED_COLUMNS.length} restricted columns`);
}

// A star select would defeat the whole check, since it exports whatever the
// table happens to hold next year.
if (/\.select\(\s*["'`]\*/.test(route)) {
  fail('the route uses select("*") somewhere — columns must be named, or a new column exports itself');
} else {
  ok("every query names its columns, so a new column never exports itself");
}

// ── client_private is never touched at all ───────────────────
if (/client_private/.test(route)) {
  fail("the route reads client_private, which is where the restricted detail lives");
} else {
  ok("client_private is not read at all");
}

// ── payroll is Admin only ────────────────────────────────────
const payroll = EXPORTS.find((e) => e.key === "contractor-hours");
if (!payroll?.adminOnly) {
  fail("contractor hours are not marked Admin only — that file says what people were paid");
} else if (exportsFor("Billing").some((e) => e.key === "contractor-hours")) {
  fail("Billing is offered the contractor hours export");
} else {
  ok("the payroll file is offered to Admin and to nobody else");
}
if (!route.includes("spec.adminOnly") || !route.includes('me.role !== "Admin"')) {
  fail("the route does not enforce adminOnly — the page hiding a link is not a permission");
} else {
  ok("and the route enforces it, rather than trusting the page to hide the link");
}

// ── the CSV itself ───────────────────────────────────────────
const csv = toCsv(["Name", "Note"], [["Smith, Ana", 'She said "yes"'], ["Ann\nLee", null]]);
if (!csv.startsWith("﻿")) {
  fail("no byte order mark — Excel will mangle every accented name");
} else if (!csv.includes('"Smith, Ana"') || !csv.includes('"She said ""yes"""')) {
  fail(`a comma or a quote is not escaped: ${JSON.stringify(csv)}`);
} else if (!csv.includes('"Ann\nLee"')) {
  fail("a newline inside a cell is not quoted, which would split one row into two");
} else {
  ok("commas, quotes and newlines survive a round trip, and Excel gets its byte order mark");
}

if (csvCell(null) !== "" || csvCell(undefined) !== "") {
  fail('an empty cell is not empty — a missing wage would read as "null" to an accountant');
} else {
  ok('a missing value is an empty cell, not the word "null"');
}

// ── the month ────────────────────────────────────────────────
const feb = monthRange("2024-02");
if (feb.start !== "2024-02-01" || feb.end !== "2024-02-29") {
  fail(`February 2024 runs ${feb.start} to ${feb.end}, and it is a leap year`);
} else {
  ok("a leap February ends on the 29th");
}
const dec = monthRange("2025-12");
if (dec.end !== "2025-12-31") fail(`December ends ${dec.end}`);
else ok("December ends on the 31st, not on the 1st of January");

for (const junk of ["", null, "2025-13", "nonsense", "2025-1"]) {
  const r = monthRange(junk);
  if (!/^\d{4}-\d{2}$/.test(r.month)) fail(`monthRange(${JSON.stringify(junk)}) gave ${r.month}`);
}
ok("a junk month in a URL falls back to this one rather than to an empty file");

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- MONTHLY EXPORT VERIFIED ---");
