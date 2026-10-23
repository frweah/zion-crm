/**
 * A day is kept the way it was written.
 *
 *   node scripts/check-kept-text.mjs        (runs before every `npm run build`)
 *
 * Rei writes a day's tasks with sub-points indented under them, and the form
 * used to throw that away: every field was trimmed on the way in, and the
 * task's Description and Notes were single-line inputs that could not hold a
 * line break at all (owner, 23 Oct 2026).
 *
 * The rule now is that what somebody typed is what the practice keeps and
 * shows. It is three things, and this checks all three - two of them by
 * running the real functions rather than by reading the source, because
 * "keeps the leading spaces" is a thing a function either does or does not do:
 *
 *   `keepAsTyped` changes nothing but the line endings, and empties a field
 *   of pure whitespace.
 *
 *   the four fields of a day go through it, and nothing trims them.
 *
 *   wherever those fields are shown, they are shown with one class - so "the
 *   same way on the day record, the team view and the summary email" is one
 *   declaration rather than a habit. The email's end of that is held by
 *   scripts/check-end-of-day.mjs, which sends a note through the real
 *   database and compares it byte for byte.
 */
import { readFileSync } from "node:fs";
import { keepAsTyped, hasWords, splitPastedReport, KEPT_LIMIT } from "../app/(app)/end-of-day/day.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const bare = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");

// ── what keepAsTyped does, and does not do ───────────────────
const NOTE = " first line\n    - indented\n\n  last line ";
const cases = [
  ["a leading space survives", " x", " x"],
  ["a trailing space survives", "x ", "x "],
  ["indentation survives", "  a\n    b", "  a\n    b"],
  ["a blank line in the middle survives", "a\n\nb", "a\n\nb"],
  ["CRLF becomes one newline", "a\r\nb", "a\nb"],
  ["a lone CR becomes one newline", "a\rb", "a\nb"],
  ["nothing but spaces is nothing", "   \n  ", ""],
  ["nothing is nothing", "", ""],
  ["the awkward note comes back whole", NOTE, NOTE],
];
const wrong = cases.filter(([, input, want]) => keepAsTyped(input) !== want);
if (wrong.length > 0) {
  for (const [what, input, want] of wrong) {
    fail(`keepAsTyped: ${what} - ${JSON.stringify(input)} became ${JSON.stringify(keepAsTyped(input))}, wanted ${JSON.stringify(want)}`);
  }
} else {
  ok(`keepAsTyped keeps every space and line break (${cases.length} cases)`);
}

// And a field somebody has to fill in is still judged on its words.
if (hasWords("   \n ") || !hasWords("  x  ")) {
  fail("hasWords does not tell an empty field from an indented one");
} else {
  ok("and a required field is still judged on whether it says anything");
}

// ── the four fields go through it ────────────────────────────
const FIELDS = ["description", "notes", "bottlenecks", "actions_taken"];
const actions = bare(read("app/(app)/end-of-day/actions.ts"));
const untrimmed = FIELDS.filter(
  (f) => !new RegExp(`keepAsTyped\\(formData\\.get\\("${f}"\\)\\)`).test(actions),
);
const trimmed = FIELDS.filter((f) => new RegExp(`get\\("${f}"\\)[^;]*\\.trim\\(\\)`).test(actions));

if (untrimmed.length > 0) {
  fail(`the day's ${untrimmed.join(", ")} ${untrimmed.length === 1 ? "is" : "are"} read without keepAsTyped`);
} else if (trimmed.length > 0) {
  fail(`the day's ${trimmed.join(", ")} ${trimmed.length === 1 ? "is" : "are"} trimmed, so the indentation is thrown away`);
} else {
  ok(`all ${FIELDS.length} fields of a day are read as typed, and none is trimmed`);
}

// ── and are shown with the one class ─────────────────────────
//
// Asked of the rendering rather than of the file: every place one of these
// values is put on screen has to carry the class, and a value put on screen
// without it is a note whose line breaks collapse into one line.
const form = read("app/(app)/end-of-day/day-form.tsx");
const shown = [
  ["the task's description", /<span className="kept">\{l\.description\}<\/span>/],
  ["the task's notes", /className="sub kept">\{l\.notes\}</],
  ["the bottlenecks", /className="kept">\{bottlenecks \|\|/],
  ["the actions taken", /className="kept">\{actionsTaken \|\|/],
];
const plain = shown.filter(([, re]) => !re.test(form));
if (plain.length > 0) {
  fail(`shown without the kept class: ${plain.map(([what]) => what).join(", ")}`);
} else if (!/^\.kept \{[^}]*white-space: pre-wrap/m.test(read("app/globals.css"))) {
  fail("the kept class does not keep white space, so carrying it means nothing");
} else {
  ok("every one of them is shown with the one class that keeps white space");
}

// The boxes themselves have to be boxes. A single-line input cannot hold a
// line break whatever is done to the value afterwards.
const singleLine = [...form.matchAll(/<input[^>]*name="(description|notes|bottlenecks|actions_taken)"/g)];
if (singleLine.length > 0) {
  fail(`${singleLine.map((m) => m[1]).join(", ")} is a single-line input, which cannot hold a line break`);
} else if (!/function Growing\(/.test(form)) {
  fail("the day's form has no growing box, so nothing grows with the text");
} else if (/onKeyDown[^}]*"Tab"/.test(form)) {
  fail("the day's form captures Tab, which is how somebody moves off a field");
} else {
  ok("the fields are boxes that grow, and Tab is left alone");
}

// ── a pasted list, however somebody numbers it ───────────────
const pasted = splitPastedReport(
  [
    "Here is my day",
    "- rang the counselor",
    "1. chased the intake",
    "2) [Pending] book the interview",
    "3. ",
    "    4. indented, still a task",
    "not a task at all",
    "* [In-Progress] writing the report",
  ].join("\r\n"),
);
const want = [
  ["Complete", "rang the counselor"],
  ["Complete", "chased the intake"],
  ["Pending", "book the interview"],
  ["Complete", "indented, still a task"],
  ["In-Progress", "writing the report"],
];
const got = pasted.map((l) => [l.status, l.description]);
if (JSON.stringify(got) !== JSON.stringify(want)) {
  fail(`a pasted list read as ${JSON.stringify(got)}, wanted ${JSON.stringify(want)}`);
} else {
  ok(`a pasted list reads hyphens and numbers the same way (${got.length} tasks, two kinds of number)`);
}

if (!Number.isInteger(KEPT_LIMIT) || KEPT_LIMIT < 500) {
  fail(`the limit on a field is ${KEPT_LIMIT}, which is not a length somebody could write`);
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- KEPT TEXT VERIFIED ---");
