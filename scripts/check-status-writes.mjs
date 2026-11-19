/**
 * A write that changed nothing is not a write that worked.
 *
 *   node scripts/check-status-writes.mjs
 *
 * Eight writes across two files changed an authorization with
 * `update(...).eq("id", id)` and reported success on whatever came back -
 * which for PostgREST includes "no error, nothing changed": a policy that
 * refuses, a row somebody deleted while the list was on screen, an id that was
 * never there. The screen then said "Ready to bill" over a record that had not
 * moved. That is the `sms_messages` fault, and Billing had seven of it: the
 * three the ruling named - Mark ready to bill, the move to Submitted after the
 * packet sends, Closed with the reason - and four more found while changing
 * them, including a second close. Money's follow-up was the eighth and was
 * already counting its rows.
 *
 * Since 0375 they all go through `writeOne`, which returns the ids and insists
 * on exactly one. This check is why that stays true: a convention is a thing
 * the ninth write will not know about, so the rule is that a server action
 * does not write the table at all.
 *
 * What it asks:
 *
 *   1. no `"use server"` file reaches `.from("authorizations").update(`;
 *   2. `lib/authorization-writes.ts` does, exactly once - the helper is the
 *      one place the write lives, and a helper that had stopped writing would
 *      make rule 1 pass by accident;
 *   3. and the actions call it, which is what makes rules 1 and 2 about live
 *      code rather than about a file nobody uses.
 *
 * The chain has to be contiguous - `.from("authorizations")` and then
 * `.update(` - because the first version of this allowed three hundred
 * characters between them and read a `.select(` on authorizations followed by
 * a `.update(` on forms as one write. A question asked merely near the rule
 * passes the bug it was written for.
 *
 * It is one table, not every table, because that is the table it bit on and a
 * check wider than its evidence is a check somebody turns off. The wider rule
 * - a write asserts what it changed - is in CLAUDE.md where it belongs.
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);

/** Every .ts and .tsx under app/, as repository-relative paths. */
const walk = (dir) => {
  const out = [];
  for (const entry of readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const here = `${dir}/${entry.name}`;
    if (entry.isDirectory()) out.push(...walk(here));
    else if (/\.tsx?$/.test(entry.name)) out.push(here);
  }
  return out;
};

const HELPER = "writeOne";
const HOME = "lib/authorization-writes.ts";
const WRITE = /\.from\("authorizations"\)\s*\.update\(/g;

// ── 1. no server action writes the table ─────────────────────
let served = 0;
let callers = 0;
let calls = 0;

for (const file of walk("app")) {
  const src = readFileSync(path.join(root, file), "utf8");
  if (!/^\s*["']use server["']/m.test(src)) continue;
  served += 1;

  for (const write of src.matchAll(WRITE)) {
    const line = src.slice(0, write.index).split("\n").length;
    problems.push(
      `${file}:${line} updates the authorizations table directly. It goes through ${HELPER} (${HOME}), which insists exactly one row changed (0375).`,
    );
  }

  const here = [...src.matchAll(new RegExp(`\\b${HELPER}\\(`, "g"))].length;
  if (here > 0) {
    callers += 1;
    calls += here;
  }
}

if (!served) {
  problems.push('no "use server" file was found under app/, which means this check is reading the wrong thing.');
} else if (!problems.length) {
  ok(`none of the ${served} server actions writes the authorizations table itself`);
}

// ── 2. and the helper does, once ─────────────────────────────
const helper = readFileSync(path.join(root, HOME), "utf8");
const inside = [...helper.matchAll(WRITE)].length;
if (inside !== 1) {
  problems.push(
    `${HOME} writes the authorizations table ${inside} time(s). It is the one place that write lives, so rule 1 above means nothing unless it is exactly once.`,
  );
} else {
  ok(`and ${HOME} does, exactly once`);
}

// ── 3. and the actions use it ────────────────────────────────
if (calls < 2) {
  problems.push(
    `only ${calls} server action call(s) ${HELPER}, which means the writes went somewhere this check cannot see.`,
  );
} else {
  ok(`${calls} write(s) across ${callers} action file(s) go through it`);
}

// ── 4. and it insists on one ─────────────────────────────────
const INSISTS = [
  // The decision itself: one row is the answer and nothing else is.
  /if \(n === 1\) return null;/,
  // And every other count gets a sentence, which is what the screen shows.
  /if \(n === 0\) \{/,
];
const loose = INSISTS.filter((rule) => !rule.test(helper));
if (loose.length) {
  problems.push(
    `${HOME} no longer insists on exactly one row — ${loose.join(" and ")} is missing — so every call site above goes through a helper that waves writes through.`,
  );
} else {
  ok("and it insists on exactly one row, with a sentence for every other count");
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- A WRITE COUNTS ITS ROWS ---");
