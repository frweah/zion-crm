/**
 * Money is dollars, in American grouping, wherever this runs.
 *
 *   node scripts/check-currency.mjs
 *
 * `money()` - the formatter most screens, the PDFs and the exports go through
 * - passed `undefined` as its locale, which means "whatever the machine
 * thinks". The machine is a serverless function whose locale is nobody's
 * decision. The dollar sign was never in doubt; it is written in. But
 * $120,095.00 and $120.095,00 are the same number told two ways, and a
 * counselor reading the second one on an invoice is reading a different
 * figure. The same fault `fmtStamp` had with the time zone, in the column
 * next door.
 *
 * So three things are checked, over every .ts and .tsx the practice ships:
 *
 *   1. No currency symbol other than the dollar appears in code.
 *   2. Every formatter that formats money names a locale, and the locale is
 *      en-US. `undefined`, nothing at all, or anything else fails.
 *   3. Every `style: "currency"` names USD.
 *
 * And then the rules are run, rather than read: `money()` and
 * `formatPayRate()` are called over awkward numbers and the output compared
 * against what an American reader expects. A regex over the source can be
 * satisfied by a formatter that is never called; this cannot.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { money, formatPayRate } from "../lib/constants.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

// ── the rules, run ───────────────────────────────────────────

const cases = [
  [0, "$0.00"],
  [5, "$5.00"],
  [1234.5, "$1,234.50"],
  [120095, "$120,095.00"],
  [1234567.891, "$1,234,567.89"],
  [-42.5, "-$42.50"],
  [null, "$0.00"],
];

let wrong = 0;
for (const [input, expected] of cases) {
  const got = money(input);
  if (got !== expected) {
    wrong += 1;
    fail(`money(${JSON.stringify(input)}) is "${got}", and an American reader expects "${expected}"`);
  }
}
if (wrong === 0) ok(`money() reads as dollars at ${cases.length} awkward figures, grouped the American way`);

// A rate is the one figure allowed four decimals: 5.625 an hour became 5.63 on
// somebody's record once (lib/constants.ts), which is what formatPayRate is
// for. It is money too, so it is held to the same grouping.
const rate = formatPayRate(5.625, "Hourly");
if (rate !== "$5.625 an hour") {
  fail(`formatPayRate(5.625, "Hourly") is "${rate}", expected "$5.625 an hour"`);
} else if (formatPayRate(1234.5, "Flat") !== "$1,234.50 flat") {
  fail(`formatPayRate(1234.5, "Flat") is "${formatPayRate(1234.5, "Flat")}"`);
} else {
  ok("a pay rate keeps its fractions of a cent, and groups the same way");
}

// ── and no formatter can produce anything else ───────────────

function sources(dir, found = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== ".next") sources(path, found);
    } else if (name.endsWith(".ts") || name.endsWith(".tsx")) {
      found.push(path);
    }
  }
  return found;
}

/** Everything that is money and is not a dollar. */
const OTHER_SYMBOLS = /[£€¥₹₩₽₪₫ƒ]|\bGBP\b|\bEUR\b|\bCAD\b|\bAUD\b/;

/** A formatter whose numbers are money: it names a currency, or a dollar sign. */
const FORMATS_MONEY = /(style:\s*["']currency["'])/;

let read = 0;
let localed = 0;

for (const path of [...sources("app"), ...sources("lib")]) {
  const src = readFileSync(path, "utf8");
  read += 1;
  const lineAt = (i) => src.slice(0, i).split("\n").length;

  for (const m of src.matchAll(new RegExp(OTHER_SYMBOLS.source, "g"))) {
    // A comment is not a screen. Mentioning sterling to explain why it is not
    // used is allowed; printing it is not.
    const line = src.split("\n")[lineAt(m.index) - 1] ?? "";
    if (/^\s*(\/\/|\*|\/\*)/.test(line)) continue;
    fail(`${path}:${lineAt(m.index)} has "${m[0]}" in it, and the practice bills in dollars`);
  }

  // Every currency formatter: the locale and the currency, both named.
  for (const m of src.matchAll(/(?:toLocaleString|NumberFormat)\s*\(\s*([^,)]*)\s*,\s*\{([^}]*)\}/gs)) {
    const locale = m[1].trim();
    const options = m[2];
    if (!FORMATS_MONEY.test(options) && !/minimumFractionDigits/.test(options)) continue;
    localed += 1;
    if (locale === "" || locale === "undefined") {
      fail(
        `${path}:${lineAt(m.index)} formats money without naming a locale, so the machine decides ` +
          `whether a thousand is 1,000 or 1.000`,
      );
    } else if (!/^["']en-US["']$/.test(locale)) {
      fail(`${path}:${lineAt(m.index)} formats money in ${locale}, and the practice reads en-US`);
    }
    const currency = options.match(/currency:\s*["']([A-Z]{3})["']/);
    if (FORMATS_MONEY.test(options) && (!currency || currency[1] !== "USD")) {
      fail(`${path}:${lineAt(m.index)} formats a currency that is not USD (${currency?.[1] ?? "unnamed"})`);
    }
  }
}

if (localed === 0) {
  fail("no money formatter was found in app/ or lib/, so this check proves nothing");
} else if (problems.length === 0) {
  ok(`all ${localed} money formatters in ${read} files name en-US, and USD where they name a currency`);
}

if (problems.length) {
  console.error("\nFAILED");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- CURRENCY VERIFIED ---");
