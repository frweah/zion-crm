/**
 * What a screen shows for an authorization that has no USOR number.
 *
 *   node --experimental-strip-types scripts/check-auth-number-display.mjs
 *
 * The practice has authorizations with no number: a coaching month opens
 * itself before USOR has issued one, and six records on file have never had
 * one. Something has to be shown in a dropdown and a list, and over time four
 * different things were - a "~~" prefix, "(workbook) coaching 1006",
 * "(no number)", and an empty cell. The owner found the "~~" on screen on
 * 26 Oct 2026 and asked what wrote it.
 *
 * The answer is now one place: `authorizationLabel` and
 * `authorizationNumberLabel` in lib/billing.ts, which say "No number yet" and,
 * where there is room, what the record is for. This holds that down two ways.
 *
 * The first is that the wording lives in the helpers and nowhere else, so a
 * screen cannot quietly invent a fifth version of it.
 *
 * The second is the shape of the bug rather than its text: `number || "…"` and
 * `number ?? "…"` are how every one of those four stand-ins got written. A
 * fallback for a missing number is a decision about what the practice calls a
 * record it has not been given a number for, and that decision is not a
 * screen's to make on its own.
 */
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (name === "node_modules" || name.startsWith(".")) return [];
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
const rel = (f) => path.relative(root, f).split(path.sep).join("/");

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

/**
 * What the app runs and what a person reads: `app` and `lib`.
 *
 * Not `scripts`. Two of those exist to clear the "(workbook)" placeholders out
 * and name them in order to find them, and a one-off tool that deletes a thing
 * is not a screen that shows it.
 *
 * And not comments anywhere. The house style explains *why* at length, so the
 * history of each stand-in is written down in the files that used to print it
 * - which is the point of writing it down. A rule about what a screen says,
 * applied to a comment saying what a screen used to say, is nonsense.
 */
const code = ["app", "lib"]
  .flatMap((d) => walk(path.join(root, d)))
  .filter((f) => /\.(ts|tsx|mjs)$/.test(f));

const stripComments = (s) =>
  s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");
const read = (f) => stripComments(readFileSync(f, "utf8"));

/** The one file allowed to decide the wording. */
const HOME = "lib/billing.ts";

// ── the wording lives in one place ───────────────────────────
const saysIt = code.filter((f) => rel(f) !== HOME && /No number yet/.test(read(f)));
if (saysIt.length) {
  fail(`"No number yet" is written in ${saysIt.map(rel).join(", ")} rather than taken from ${HOME}`);
} else {
  ok(`what an unnumbered authorization is called is written only in ${HOME}`);
}

if (!/No number yet/.test(read(path.join(root, HOME)))) {
  fail(`${HOME} no longer says what an unnumbered authorization is called`);
} else {
  ok(`and ${HOME} still says it, so the check is reading something`);
}

// ── the stand-ins that came before are gone ──────────────────
// Each of these was on screen at some point. The SQL that removed them is
// history and keeps its own words; the app and the checks must not.
const GONE = [
  ['"~~"', /["'`]~~/],
  ["(no number)", /\(no number\)/],
  ["(workbook)", /\(workbook\)/],
];
for (const [what, pattern] of GONE) {
  const hits = code.filter((f) => pattern.test(read(f)));
  if (hits.length) fail(`${what} is still in ${hits.map(rel).join(", ")}`);
}
if (!problems.length) ok("none of the stand-ins that came before it is still on a screen");

// ── and nothing reads one as a signal ────────────────────────
const READS_IT = /\.(?:startsWith|includes|indexOf)\(\s*["'`](?:~~|\(workbook\))/;
const signals = code.filter((f) => READS_IT.test(read(f)));
if (signals.length) {
  fail(`${signals.map(rel).join(", ")} tests a number for a marker instead of asking has_usor_number`);
} else {
  ok("nothing decides whether a record has a number by looking for a marker in it");
}

// ── no screen invents its own fallback ───────────────────────
/**
 * `number` with a string on the other side of `||` or `??`.
 *
 * An empty string is allowed: `number ?? ""` is not a label, it is a value on
 * its way to a form field or a sort key, and every one of those in the CRM is
 * exactly that.
 */
const OWN_FALLBACK = /\bnumber\s*(?:\|\||\?\?)\s*["'`](?!["'`])/g;
for (const f of code) {
  if (rel(f) === HOME) continue;
  const hits = [...read(f).matchAll(OWN_FALLBACK)];
  for (const h of hits) {
    fail(`${rel(f)} has its own wording for a missing number: ${h[0].trim()}…`);
  }
}
if (!problems.length) ok("no screen writes its own wording for a number that is not there");

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- AUTHORIZATION NUMBER DISPLAY VERIFIED ---");
