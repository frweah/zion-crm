/**
 * A migration that can refuse a write says how it gets along with the code
 * that is live (owner, 23 November 2026).
 *
 * The rule exists because of what happened the same evening. 0378 added a
 * trigger that refuses a hand-written contact note with no method, and it was
 * applied before the push. The push failed its deploy check on a fault in the
 * check itself, production rolled back one commit, and for twenty minutes the
 * database held a rule the live code could not satisfy: a Meeting note typed
 * on the Notes tab would have been refused with a sentence that screen had no
 * field to answer. Nobody wrote one, so nobody was caught.
 *
 * So a refusal is applied **after** the code that satisfies it is live, or it
 * is shaped to tolerate the old code until it is - never ahead of a push that
 * can roll back. Which of the two a migration is cannot be guessed from its
 * SQL, so each one says, in a line this reads:
 *
 *   -- Tolerates the old code: <why>
 *   -- Needs the new code live first: `<field>`
 *   -- The code that sends it: <paths>
 *
 * And the second shape is tied to the repository: the files it names have to
 * exist and have to mention the field, because a refusal that nothing sends
 * is a refusal that breaks whatever is live whether it was pushed first or
 * not.
 *
 * Two things this deliberately does not claim to know. It cannot know what is
 * live - prebuild runs inside the deployment it would be asking about, which
 * is the same reason check-deployed cannot live here. And it cannot know when
 * a migration was applied. What it can do is make the hazard visible in the
 * file, at review time, in the words of whoever wrote it.
 */
import { readdir, readFile } from "node:fs/promises";

const problems = [];
const bad = (line) => problems.push(line);
const dir = new URL("../supabase/migrations/", import.meta.url);

/**
 * The rule starts at the migration that caused it.
 *
 * Not applied to the three hundred and seventy-seven before it: the rule is
 * new, and a check that failed every historical migration would be turned off
 * within the hour. Written as a number with the date beside it so that moving
 * it is a decision somebody takes on purpose.
 */
const FROM = 378;

/** A check constraint that permits null cannot refuse a write that omits it. */
const permitsNothing = (expr) =>
  /\b([a-z_]+)\s+is\s+null\s+or\b/i.test(expr) || /\bcoalesce\s*\(/i.test(expr);

/**
 * What in this file can refuse a write the live code already makes.
 *
 * Triggers on a table, check constraints, and columns that stop being
 * nullable. A *function* that raises is not one of these: nothing that is
 * already deployed calls a function this migration introduces, so it cannot
 * refuse anything until the code that calls it is there - which is the
 * opposite of the hazard.
 */
function refusals(sql) {
  const found = [];

  // A trigger whose function raises. Both halves are usually in the same
  // file, which is what makes this answerable without the database.
  for (const m of sql.matchAll(
    /create trigger\s+(\w+)[\s\S]{0,400}?execute function\s+(?:public\.)?(\w+)\s*\(/gi,
  )) {
    const [, trigger, fn] = m;
    const body = sql.match(
      new RegExp(`function\\s+(?:public\\.)?${fn}\\s*\\(\\)[\\s\\S]*?\\$function\\$|function\\s+(?:public\\.)?${fn}\\s*\\(\\)[\\s\\S]*?\\$\\$;`, "i"),
    );
    const raises = body ? /raise exception/i.test(body[0]) : /raise exception/i.test(sql);
    if (raises) found.push(`the trigger ${trigger}`);
  }

  for (const m of sql.matchAll(/add constraint\s+(\w+)\s*\n?\s*check\s*\(([\s\S]{0,400}?)\)\s*;/gi)) {
    const [, name, expr] = m;
    if (!permitsNothing(expr)) found.push(`the constraint ${name}`);
  }

  for (const m of sql.matchAll(/alter column\s+(\w+)\s+set not null/gi)) {
    found.push(`${m[1]} becoming not null`);
  }
  for (const m of sql.matchAll(/add column\s+(?:if not exists\s+)?(\w+)\s+[\w ()]*?not null([^;]*);/gi)) {
    if (!/default/i.test(m[2])) found.push(`the new column ${m[1]}, which cannot be null`);
  }

  return found;
}

const TOLERATES = /--\s*Tolerates the old code:\s*(.+)/i;
const NEEDS = /--\s*Needs the new code live first:\s*(.+)/i;
const SENDS = /--\s*The code that sends it:\s*([\s\S]{0,300}?)(?:\n\s*(?:--\s*\n|[^-\s])|\n\n)/i;

const files = (await readdir(dir)).filter((f) => f.endsWith(".sql")).sort();
let asked = 0;
let declared = 0;

for (const name of files) {
  const number = Number(name.slice(0, 4));
  if (!Number.isFinite(number) || number < FROM) continue;
  const sql = await readFile(new URL(name, dir), "utf8");
  const can = refusals(sql);
  if (can.length === 0) continue;
  asked += 1;

  const tolerates = sql.match(TOLERATES);
  const needs = sql.match(NEEDS);

  if (!tolerates && !needs) {
    bad(
      `${name} can refuse a write (${can.join(", ")}) and does not say how it gets along with the live code. ` +
        'Add "-- Tolerates the old code: <why>" or "-- Needs the new code live first: `<field>`".',
    );
    continue;
  }
  if (tolerates && needs) {
    bad(`${name} says both that it tolerates the old code and that it needs the new code first`);
    continue;
  }
  declared += 1;

  if (tolerates) {
    if (tolerates[1].trim().split(/\s+/).length < 3) {
      bad(`${name} says it tolerates the old code and does not say why`);
    }
    continue;
  }

  // Needs the new code: the field, and the code that sends it.
  const field = needs[1].match(/`([\w.]+)`/)?.[1];
  if (!field) {
    bad(`${name} needs the new code live first and does not name the field in backticks`);
  }
  const sends = sql.match(SENDS);
  if (!sends) {
    bad(
      `${name} needs the new code live first and does not name the code that sends it. ` +
        'Add "-- The code that sends it: <paths>".',
    );
    continue;
  }
  const paths = [...sends[1].matchAll(/([\w()[\]@./-]+\.(?:tsx|ts|mjs|sql))(?![\w])/g)].map((m) => m[1]);
  if (paths.length === 0) {
    bad(`${name} names no file at all as the code that sends ${field ?? "it"}`);
    continue;
  }
  for (const path of paths) {
    let body = "";
    try {
      body = await readFile(new URL(`../${path}`, import.meta.url), "utf8");
    } catch {
      bad(`${name} says ${path} sends ${field ?? "it"}, and there is no such file`);
      continue;
    }
    if (field && !body.includes(field)) {
      bad(`${name} says ${path} sends \`${field}\`, and ${path} never mentions it`);
    }
  }
}

if (asked === 0) {
  bad(
    `no migration from ${FROM} onwards can refuse a write, so this check asked nothing - ` +
      "which is either true or a sign the detector has stopped finding them",
  );
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with how a migration meets the live code`);
  process.exit(1);
}
console.log(
  `  ok  all ${asked} migration(s) from ${FROM} that can refuse a write say how they meet the live code (${declared} declared)`,
);
