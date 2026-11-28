/**
 * One engine for what needs doing, asked of the code.
 *
 *   node --experimental-strip-types scripts/check-next-steps.mjs
 *
 * The database half is `verify_one_whats_next`, which asks whether the board
 * row, the record's list and the practice-wide answer are the same answer for
 * every active client. This is the half no SQL can see: that nothing in the
 * application works the question out for itself, that every kind the rules
 * can return has a word on screen, and that the one scale means one thing.
 *
 * It exists because six things answered this question and none asked another.
 * The expensive one was not any single wrong rule - it was that each was
 * plausible on its own screen, so nobody could tell which was wrong without
 * reading all six.
 */
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import {
  KINDS,
  KIND_WORD,
  kindWord,
  kindCount,
  severityClass,
  byKind,
  worstFirst,
  dueNow,
} from "../lib/next-steps.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);
const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");

// ── every kind the rules can return has a word ───────────────

/**
 * The vocabulary is asked of the migrations rather than of a list kept
 * beside them, because a list beside them is the thing that went stale: the
 * strip's own `WORD` map covered six of the nine kinds the old function
 * could return, so a fifth shift rendered the lowercase word "placement" on
 * a client's record and nobody found out.
 *
 * Every branch of the engine selects its kind immediately before the link it
 * opens, which is what this reads: `'quiet',` then a string starting with a
 * slash. A branch written another way is a branch this cannot see, so the
 * count is asserted too - if the engine grows a kind and this still finds
 * twelve, the pattern has stopped matching and the check is asking nothing.
 */
const migrations = readdirSync(new URL("supabase/migrations", root))
  .filter((f) => /^04(0[5-9]|[1-9][0-9])_/.test(f) && f.endsWith(".sql"))
  .map((f) => read(`supabase/migrations/${f}`));

const found = new Set();
for (const sql of migrations) {
  for (const m of sql.matchAll(/'([a-z][a-z_]*)',\s*\n?\s*'\//g)) found.add(m[1]);
}

if (found.size < 8) {
  fail(
    `only ${found.size} kinds were found in the migrations, and the engine has more than that - ` +
      "the pattern has stopped matching the way a branch is written, so this is asking nothing",
  );
} else {
  const missing = [...found].filter((k) => !KIND_WORD[k]);
  if (missing.length > 0) {
    fail(
      `${missing.join(", ")} can appear on a client's record and ${
        missing.length === 1 ? "has" : "have"
      } no word, so the screen prints the database's own key`,
    );
  } else {
    ok(`all ${found.size} kinds the rules can return have a word on screen`);
  }
}

// And the words themselves are words.
const raw = KINDS.filter((k) => KIND_WORD[k] === k || /^[a-z]/.test(KIND_WORD[k]));
if (raw.length > 0) {
  fail(`${raw.join(", ")} would render as written in the database rather than as English`);
}
for (const [kind, want] of [
  ["task", "Task"],
  ["stability", "Placement"],
  ["zz_unheard_of", "Zz unheard of"],
  ["", "To do"],
]) {
  const got = kindWord(kind);
  if (got !== want) fail(`kindWord(${JSON.stringify(kind)}) is ${JSON.stringify(got)}, expected ${want}`);
}
if (!/^[A-Z]/.test(kindWord("something_new"))) {
  fail("a kind nobody has given a word to is printed as it is stored, which is how 'stability' reached a screen");
}
if (kindCount("quiet", 1) !== "1 client quiet" || kindCount("task", 2) !== "2 tasks") {
  fail(`a count reads "${kindCount("quiet", 1)}" and "${kindCount("task", 2)}"`);
}
ok("a kind is named in words, known or not");

// ── one scale, and it means one thing ────────────────────────

const scale = [
  [1, "chip bad"],
  [2, "chip warn"],
  [3, "chip"],
  [4, "chip"],
  [null, "chip"],
];
for (const [severity, want] of scale) {
  const got = severityClass(severity);
  if (got !== want) fail(`severity ${severity} is drawn as ${JSON.stringify(got)}, expected ${want}`);
}
if (!dueNow({ severity: 1 }) || dueNow({ severity: 2 })) {
  fail("what counts as work for today is not severity 1, so the tinting and the counts disagree");
}

// Worst first, and stable between two things equally urgent.
const sample = [
  { kind: "task", what: "b", severity: 2 },
  { kind: "quiet", what: "a", severity: 3 },
  { kind: "authorization", what: "c", severity: 2 },
  { kind: "reply", what: "d", severity: 1 },
];
const order = worstFirst(sample).map((s) => s.kind).join(",");
if (order !== "reply,authorization,task,quiet") {
  fail(`the worst thing is not first: the order came out ${order}`);
}
if (worstFirst(sample).map((s) => s.what).join("") !== worstFirst([...sample].reverse()).map((s) => s.what).join("")) {
  fail("the order depends on the order the rows arrived, so a page draws differently each time");
}
const kinds = byKind(sample);
if (kinds.length !== 4 || kinds[0].kind !== "reply" || kinds[0].worst !== 1) {
  fail("the counts by kind are not worst-kind-first");
}
if (byKind([...sample, { kind: "task", what: "e", severity: 4 }]).find((k) => k.kind === "task")?.n !== 2) {
  fail("two things of one kind are not counted as two");
}
ok("one severity scale, worst first, and the same order every time");

// ── nothing works it out for itself ──────────────────────────

const sources = [];
for (const top of ["lib", "app", "scripts"]) {
  (function walk(where) {
    for (const entry of readdirSync(new URL(where, root))) {
      if (entry === "node_modules" || entry.startsWith(".")) continue;
      const rel = `${where}/${entry}`;
      if (statSync(new URL(rel, root)).isDirectory()) walk(rel);
      else if (/\.(ts|tsx|mjs)$/.test(entry) && entry !== "database.types.ts") sources.push(rel);
    }
  })(top);
}

/**
 * The computations this replaced, by name.
 *
 * Named rather than inferred, because the point is that these particular
 * answers are gone: a file calling one of them is a screen that has gone
 * back to its own rules. `lib/needs.ts` is in the list as a path, not a
 * symbol, because what it was is five rules in TypeScript with their own
 * thresholds - thirty days of silence where the threads board said fourteen.
 */
const GONE = ["client_next_actions", "client_next_actions_for", "countNeeds", "loadNeed"];

/**
 * The code, with the comments taken out.
 *
 * Two of these files explain in a comment what they used to call and why
 * it was replaced, which is worth keeping - and the first version of this
 * check read those sentences as calls and failed both files. A rule about
 * what the code does cannot be asked of the prose beside it. Same trap as
 * check-unbounded-reads, which walks a method chain into a comment and
 * loses every filter after it.
 */
const code = (f) =>
  read(f)
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/^[ \t]*\/\/.*$/gm, "");

const backAgain = sources.filter((f) => {
  const body = code(f);
  return GONE.some((g) => new RegExp(`\\b${g}\\b`).test(body)) && !f.startsWith("scripts/");
});
if (backAgain.length > 0) {
  fail(
    `${backAgain.join(", ")} still ${backAgain.length === 1 ? "calls" : "call"} one of the ` +
      "computations the engine replaced",
  );
}
if (existsSync(new URL("lib/needs.ts", root))) {
  fail("lib/needs.ts is back, and it is five rules with their own thresholds beside the engine's");
}

/**
 * Three arguments, every time.
 *
 * A defaulted parameter in this database creates a second function, granted
 * to everybody, which is why the engine takes three required ones - and why
 * a call site that leaves one out is a call site that will not compile today
 * and would quietly reach the wrong function the day somebody adds a default.
 */
const callers = sources.filter((f) => /rpc\("next_steps"/.test(read(f)));
if (callers.length === 0) {
  fail("nothing calls next_steps, so every screen is still working it out for itself");
}
for (const f of callers) {
  const body = read(f);
  for (const call of body.matchAll(/rpc\("next_steps",\s*\{([\s\S]{0,200}?)\}\)/g)) {
    const args = call[1];
    for (const want of ["p_scope", "p_person", "p_client"]) {
      if (!args.includes(want)) {
        fail(`${f} calls next_steps without naming ${want}, and all three are required`);
      }
    }
  }
}
ok(`${callers.length} screens read the engine, each naming all three arguments`);

// ── and the board filters on the engine's answer ─────────────

const shape = read("lib/clients-board-shape.ts");
if (/export const outOfContact|export const taskOverdue/.test(shape)) {
  fail(
    "the board shape still decides a fortnight of silence or an overdue task for itself, which " +
      "is two of the six answers this replaced",
  );
}
const tiles = shape.slice(shape.indexOf("export const TILES"), shape.indexOf("/** A stage change"));
if (!/has\(r, "quiet"\)/.test(tiles) || !/has\(r, "authorization"\)/.test(tiles)) {
  fail("a tile counts something the cell beside it is not answering: the tiles must filter on next_kinds");
}
if (/daysSince|last_contact_at/.test(tiles)) {
  fail("a tile is still doing its own arithmetic on when somebody was last contacted");
}
const board = read("app/(app)/clients/stage-board.tsx");
if (/attention_urgency/.test(board)) {
  fail("the board still reads the old authorization urgency, which is not the one scale");
}
if (!/row\.next_step/.test(board)) {
  fail("the board does not show the engine's answer");
}
ok("the board shows one cell and its tiles filter on the same answer");

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with what needs doing`);
  process.exit(1);
}
console.log("\n  ok  one engine answers what needs doing, every kind has a word, and one scale means one thing");
