/**
 * No screen shows a time in the server's zone.
 *
 *   node scripts/check-times.mjs
 *
 * `fmtStamp` read `toLocaleString(undefined, …)`, which names no zone, so it
 * used the zone of whatever ran it. Almost every list in this system is
 * rendered on the server, and on Vercel the server is UTC - so **every
 * timestamp on every list was six or seven hours ahead of the practice.** A
 * text sent at four in the afternoon read as eleven at night.
 *
 * The same bug was fixed once before, for `today()`: dates stamped after
 * supper landed on tomorrow. It was fixed for the date and not for the time,
 * which is why this check exists rather than a note in a comment.
 *
 * So: every `toLocale*` call that formats a date or a time names a zone. The
 * ones that format a number are a different thing and are let through by what
 * is in their options, not by a list of files - a list of files is the thing
 * that goes stale.
 *
 * And the other half of the same bug, which is easier to get wrong: a
 * **date-only** string. `new Date("2026-11-03")` is midnight UTC, which in
 * Mountain time is the 2nd at six in the evening, so rendering it with a zone
 * moves it to the day before. The fix is to anchor it at noon, and this
 * asserts that any date-only string handed to `new Date` is.
 */
import { readFile, readdir } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const ROOTS = [new URL("../app/", import.meta.url), new URL("../lib/", import.meta.url)];

async function files(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const next = new URL(`${entry.name}${entry.isDirectory() ? "/" : ""}`, dir);
    if (entry.isDirectory()) {
      if (entry.name === "node_modules" || entry.name.startsWith(".")) continue;
      out.push(...(await files(next)));
    } else if (/\.(ts|tsx)$/.test(entry.name) && entry.name !== "database.types.ts") {
      out.push(next);
    }
  }
  return out;
}

const all = [];
for (const root of ROOTS) all.push(...(await files(root)));

/** Everything between the call's opening bracket and its match. */
function argsOf(src, at) {
  let depth = 0;
  for (let i = at; i < src.length && i < at + 4000; i++) {
    if (src[i] === "(") depth += 1;
    else if (src[i] === ")") {
      depth -= 1;
      if (depth === 0) return src.slice(at, i + 1);
    }
  }
  return src.slice(at, at + 400);
}

/**
 * Whether a `toLocale…String` call is formatting a time or a number.
 *
 * The first version of this asked whether the options named a currency or a
 * fraction, and so read `Number(n).toLocaleString("en-US")` - no options at
 * all - as a date. Six number formatters were given a timeZone before the
 * compiler objected.
 *
 * `toLocaleDateString` and `toLocaleTimeString` are dates, always.
 * `toLocaleString` is a date only when something says so: the receiver is a
 * `new Date(…)`, or the options name a field only a date has.
 */
const DATE_FIELD = /\b(timeZone|weekday|era|year|month|day|hour|minute|second|dayPeriod|dateStyle|timeStyle)\s*:/;
const NUMERIC_FIELD = /\b(currency|minimumFractionDigits|maximumFractionDigits|notation|style\s*:\s*"(percent|currency|decimal)")\b/;

function formatsATime(method, receiver, args) {
  if (method === "toLocaleDateString" || method === "toLocaleTimeString") return true;
  if (NUMERIC_FIELD.test(args)) return false;
  if (/\bnew Date\s*\($/.test(receiver)) return true;
  return DATE_FIELD.test(args);
}

const zoneless = [];
const unanchored = [];

for (const file of all) {
  const raw = await readFile(file, "utf8");
  // Comments out first, with their length kept so line numbers still line up.
  // `lib/report-weeks.ts` explains this very bug in prose and quotes
  // `new Date("2026-11-01")` as the example of it, which the first run of this
  // check dutifully reported as the bug.
  const src = raw
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "))
    .replace(/\/\/[^\n]*/g, (m) => " ".repeat(m.length));
  const name = file.pathname.replace(/^.*\/(app|lib)\//, "$1/");

  for (const m of src.matchAll(/\.(toLocale(?:Date|Time)?String)\s*\(/g)) {
    const args = argsOf(src, m.index + m[0].length - 1);
    const receiver = src.slice(Math.max(0, m.index - 60), m.index);
    if (!formatsATime(m[1], receiver, args)) continue;
    if (/timeZone\s*:/.test(args) || /PRACTICE_TZ/.test(args)) continue;
    const line = src.slice(0, m.index).split("\n").length;
    zoneless.push(`${name}:${line}`);
  }

  // `new Date("…")` on a bare date, which is midnight UTC and so the previous
  // day in Utah. Only the literal form can be checked here; a variable is
  // checked by the one place that formats it.
  for (const m of src.matchAll(/new Date\(\s*`?\$?\{?[^)]{0,80}?\}?`?\s*\)/g)) {
    const text = m[0];
    if (!/\d{4}-\d{2}-\d{2}/.test(text) && !/\$\{/.test(text)) continue;
    if (/T\d{2}:\d{2}/.test(text)) continue; // anchored at an hour
    if (!/\d{4}-\d{2}-\d{2}/.test(text)) continue;
    const line = src.slice(0, m.index).split("\n").length;
    unanchored.push(`${name}:${line} ${text.slice(0, 48)}`);
  }
}

if (zoneless.length) {
  fail(
    `${zoneless.length} place(s) format a date or a time without naming a zone, so they show the server's: ${zoneless.slice(0, 12).join(", ")}${zoneless.length > 12 ? ", …" : ""}`,
  );
} else {
  ok(`every date and time is formatted in a named zone (${all.length} files read)`);
}

if (unanchored.length) {
  fail(
    `${unanchored.length} place(s) build a Date from a bare date, which is midnight UTC and the day before in Utah: ${unanchored.slice(0, 8).join("; ")}`,
  );
} else {
  ok("no date-only string is read as midnight UTC");
}

// ── and the one formatter everything shares names the zone ───
const constants = await readFile(new URL("../lib/constants.ts", import.meta.url), "utf8");
const at = constants.indexOf("export function fmtStamp");
const body = at < 0 ? "" : constants.slice(at, constants.indexOf("}", constants.indexOf("return", at)));
if (at < 0) {
  fail("lib/constants.ts has no fmtStamp, which is what most lists use");
} else if (!/timeZone:\s*PRACTICE_TZ/.test(body)) {
  fail("fmtStamp does not name the practice's zone, so every list using it shows the server's");
} else {
  ok("fmtStamp, which most lists use, names the practice's zone");
}

if (!/export const PRACTICE_TZ = "America\/Denver"/.test(constants)) {
  fail("PRACTICE_TZ is not America/Denver");
} else {
  ok("and the practice's zone is Utah's");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- TIMES VERIFIED ---");
