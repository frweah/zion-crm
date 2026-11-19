/**
 * A paid date comes with its payment, and the Edit form does not offer one.
 *
 *   node scripts/check-paid-date-one-door.mjs
 *
 * 0375 closed `paid_on` and `paid_amount` in `edit_authorization`, which is
 * the half of the rule that cannot be got round. This is the other half: a
 * form that still offers the boxes is a form whose Save now refuses, and
 * somebody would meet that refusal instead of meeting the right screen.
 *
 * Why it is worth a check rather than a convention. The two boxes sat on the
 * Edit form from 14 October to 19 November, and in that time one of them wrote
 * a paid date onto V1045641 with no money behind it - so the record said "Paid
 * on 2026-11-11" and the board said "no payment after 14 days" on the same
 * row. What goes wrong next is the field growing back, because adding one to a
 * list of twenty looks like nothing.
 *
 * What it asks:
 *
 *   1. no form bound to `editAuthorization` carries a field named `paid_on` or
 *      `paid_amount`. This is the fault itself, in the shape it had.
 *   2. no argument object passed to any `.rpc(...)` carries either as a key,
 *      which is how `edit_authorization` was handed them underneath.
 *   3. no `.update({...})` on `authorizations` writes either, which is the way
 *      round that would skip the function altogether.
 *
 * What it deliberately leaves alone: every other form that says `paid_on`. The
 * typed-in authorization sends one to `add_authorization`, which calls
 * `record_payment` with it; Date paid sends one to `correct_payment_date`; the
 * contractors' and the bills' screens mean a different table altogether. The
 * rule is not "nobody types a date" - it is "a paid date on an authorization
 * arrives as a payment".
 *
 * Reading them is untouched, and most of Billing does: the board draws the
 * paid date, the client's tab sorts on it, Money counts on it.
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const read = (p) => readFileSync(path.join(root, p), "utf8");

/** Every .ts and .tsx under a directory, as repository-relative paths. */
const walk = (dir) => {
  const out = [];
  for (const entry of readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const here = `${dir}/${entry.name}`;
    if (entry.isDirectory()) out.push(...walk(here));
    else if (/\.tsx?$/.test(entry.name)) out.push(here);
  }
  return out;
};
const FILES = [...walk("app"), ...walk("lib")];

/** The money fields, by the names the form and the function use for them. */
const CLOSED = ["paid_on", "paid_amount"];

/** The brace-matched object literal that starts at or after `from`. */
const objectAt = (src, from) => {
  const open = src.indexOf("{", from);
  if (open < 0) return "";
  let depth = 0;
  for (let i = open; i < src.length; i += 1) {
    if (src[i] === "{") depth += 1;
    else if (src[i] === "}") {
      depth -= 1;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  return src.slice(open);
};

/** `name:` as a key in an object literal, rather than as a value passed to one. */
const hasKey = (text, name) => new RegExp(`(^|[\\s{,])${name}\\s*:`).test(text);

// ── 1. the form that had the fault ───────────────────────────
//
// The dispatcher is the second thing destructured out of useActionState, and
// the form is bound to that rather than to the action itself.
const ACTION = "editAuthorization";
const screens = FILES.filter((f) => f.endsWith(".tsx") && new RegExp(`useActionState\\(\\s*${ACTION}\\b`).test(read(f)));
let edited = 0;

for (const screen of screens) {
  const src = read(screen);
  /*
   * Bounded to the component that binds it, not to the file.
   *
   * Every component in panel.tsx names its dispatcher `action`, so looking
   * for `<form action={action}>` anywhere in the file found Date paid - which
   * asks for a paid date on purpose, and sends it to `correct_payment_date`.
   * A component binds its action and then renders its form, so the next
   * `useActionState(` is the end of this one's forms.
   */
  const binds = [...src.matchAll(/const\s*\[[^\]]*?,\s*([A-Za-z0-9_]+)[^\]]*\]\s*=\s*useActionState\(\s*([A-Za-z0-9_]+)/g)];
  const forms = [];
  for (const [i, m] of binds.entries()) {
    if (m[2] !== ACTION) continue;
    const until = binds[i + 1]?.index ?? src.length;
    const body = src.slice(m.index, until);
    let at = 0;
    for (;;) {
      const open = body.indexOf(`<form action={${m[1]}}`, at);
      if (open < 0) break;
      const close = body.indexOf("</form>", open);
      forms.push(body.slice(open, close < 0 ? body.length : close));
      at = close < 0 ? body.length : close;
    }
  }
  if (!forms.length) {
    problems.push(`${screen} binds ${ACTION} and has no form posting to it, so this check cannot see what it asks for.`);
    continue;
  }
  for (const form of forms) {
    for (const name of CLOSED) {
      if (new RegExp(`<(?:input|select|textarea)\\b[^>]*name="${name}"`).test(form)) {
        problems.push(
          `${screen} offers ${name} on the form that saves the record. The money has one door since 0375, so Save would refuse this box.`,
        );
      }
    }
  }
  edited += 1;
}

if (!edited) {
  problems.push(`no screen binds ${ACTION}, which means this check is reading the wrong thing.`);
} else if (!problems.length) {
  ok(`neither paid date nor amount paid is on the ${edited} ${edited === 1 ? "screen" : "screens"} that save a record`);
}

// ── 2 and 3. and nothing hands them to the database ──────────
let calls = 0;
let updates = 0;

for (const file of FILES) {
  const src = read(file);

  // `p_fields: { paid_on: … }` is nested inside the argument object, so the
  // whole object is read rather than its top level.
  for (const call of src.matchAll(/\.rpc\(\s*"([a-z_]+)"\s*,/g)) {
    const args = objectAt(src, call.index + call[0].length);
    for (const name of CLOSED) {
      // As a key, not as a value: `p_received: paid_on` is handing the date
      // *to* record_payment, which is the door it is meant to go through.
      if (hasKey(args, name)) {
        problems.push(
          `${file} passes ${name} to ${call[1]}. The money goes through record_payment, correct_payment_date or remove_payment (0375).`,
        );
      }
    }
    calls += 1;
  }

  for (const write of src.matchAll(/\.from\("authorizations"\)[\s\S]{0,200}?\.update\(/g)) {
    const patch = objectAt(src, write.index + write[0].length - 1);
    for (const name of CLOSED) {
      if (hasKey(patch, name)) {
        problems.push(`${file} writes ${name} straight onto the authorizations table (0375).`);
      }
    }
    updates += 1;
  }
}

if (!calls) {
  problems.push("no .rpc( call was found in app/ or lib/, which means this check is reading the wrong thing.");
} else if (!problems.length) {
  ok(`and none of the ${calls} database calls hands one over, across ${updates} direct write(s)`);
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- A PAID DATE COMES WITH ITS PAYMENT ---");
