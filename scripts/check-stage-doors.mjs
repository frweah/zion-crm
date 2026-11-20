/**
 * Every door into Job Placement asks what the stage means.
 *
 *   node scripts/check-stage-doors.mjs
 *
 * Job Placement is a job, at an employer, on a day. Since 0374 `move_client`
 * refuses a move into it that cannot name both, which settles the rule for
 * every door at once - that is the whole reason the rule lives in the
 * database. What the database cannot do is put a box on the screen, and a
 * stage that refuses a move with nowhere to type the answer is the fault the
 * record screen already had once: "Move stage" answered "Say why they are
 * moving" every time it was pressed, with nowhere to say it.
 *
 * So this asks the screens. There are three doors today - the board's Move,
 * the administrator's Approve, and the record's own picker - and the thing
 * that goes wrong next is a fourth one written by somebody who does not know
 * about the refusal.
 *
 * What it asks, in order:
 *
 *   1. every call to `move_client` or `decide_stage_request` that could carry
 *      a client into Job Placement passes `p_employer` and `p_start`. A call
 *      whose stage is a literal that is not Job Placement cannot, and is left
 *      alone - that is the intake's move to Assessment.
 *   2. the forms behind those actions ask for both, by the names the actions
 *      read: `employer` and `hire_date`.
 *   3. and every one of those fields is `required`, so the browser asks before
 *      the round trip that would be refused anyway.
 *   4. except where the client is already in the stage that was asked for, in
 *      which case the request closes without a move and neither field is read,
 *      so neither is asked (owner, 19 November 2026).
 *
 * Step 2 is the loose one and is written down as loose: it finds the forms
 * bound to the action and asks whether one of them carries the two fields,
 * which a form shown only for Job Placement satisfies and a form that never
 * shows them does not. Whether the right form shows them at the right moment
 * is the hand check on Clients › Board, as the definition of done says.
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const read = (p) => readFileSync(path.join(root, p), "utf8");

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
const FILES = walk("app");

/** The object literal that starts at `from`, by matching its braces. */
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
  return "";
};

/** The exported action a position in the file sits inside. */
const actionAround = (src, at) => {
  const before = src.slice(0, at);
  const starts = [...before.matchAll(/export\s+async\s+function\s+([A-Za-z0-9_]+)\s*\(/g)];
  return starts.length ? starts[starts.length - 1][1] : null;
};

// ── 1. the calls ─────────────────────────────────────────────
/** The actions that can carry somebody into Job Placement, and where they are. */
const doors = new Map();

for (const file of FILES) {
  const src = read(file);
  for (const m of src.matchAll(/\.rpc\(\s*["'](move_client|decide_stage_request)["']/g)) {
    const args = objectAt(src, m.index);
    if (!args) {
      problems.push(`${file} calls ${m[1]} with something this check cannot read as an argument list.`);
      continue;
    }
    /*
     * A stage written out in the call can only ever be that stage. The intake
     * moves people to Assessment and will never reach Job Placement, so
     * asking it for an employer would be asking the wrong screen a question
     * it has no business answering.
     */
    const stage = args.match(/p_stage\s*:\s*(.+?)\s*,\s*\n/);
    const literal = stage?.[1].match(/^["'`]([^"'`]*)["'`]$/)?.[1] ?? null;
    if (literal !== null && literal !== "Job Placement") continue;

    const name = actionAround(src, m.index);
    const where = name ? `${name} in ${file}` : file;
    for (const field of ["p_employer", "p_start"]) {
      if (!new RegExp(`\\b${field}\\s*:`).test(args)) {
        problems.push(
          `${where} can move somebody into Job Placement and does not pass ${field}, so the move would be refused with nothing to send.`,
        );
      }
    }
    if (name) doors.set(name, file);
  }
}

if (!doors.size) {
  problems.push(
    "no action calls move_client or decide_stage_request with a stage somebody chooses, which means this check is reading the wrong thing.",
  );
} else if (!problems.length) {
  ok(`all ${doors.size} actions that can reach Job Placement send the employer and the start date`);
}

// ── 2 and 3. the forms behind them ───────────────────────────
const FIELDS = ["employer", "hire_date"];
let asked = 0;

for (const [action] of doors) {
  const screens = FILES.filter((f) => f.endsWith(".tsx") && new RegExp(`useActionState\\(\\s*${action}\\b`).test(read(f)));
  if (!screens.length) continue; // an action with no form of its own, called from elsewhere

  for (const screen of screens) {
    const src = read(screen);
    // The dispatcher is the second thing destructured out of useActionState,
    // and the form is bound to that rather than to the action itself.
    const bound = [...src.matchAll(/const\s*\[[^\]]*?,\s*([A-Za-z0-9_]+)[^\]]*\]\s*=\s*useActionState\(\s*([A-Za-z0-9_]+)/g)]
      .filter((m) => m[2] === action)
      .map((m) => m[1]);

    const forms = [];
    for (const dispatcher of bound) {
      let at = 0;
      for (;;) {
        const open = src.indexOf(`<form action={${dispatcher}}`, at);
        if (open < 0) break;
        const close = src.indexOf("</form>", open);
        forms.push(src.slice(open, close < 0 ? src.length : close));
        at = close < 0 ? src.length : close;
      }
    }

    if (!forms.length) {
      problems.push(`${screen} binds ${action} and has no form posting to it, so this check cannot see what it asks for.`);
      continue;
    }
    const carries = forms.some((f) => FIELDS.every((name) => f.includes(`name="${name}"`)));
    if (!carries) {
      problems.push(
        `${screen} can move somebody into Job Placement and asks for neither the employer nor the day they started. The move would be refused with nowhere to answer.`,
      );
      continue;
    }
    for (const form of forms) {
      for (const name of FIELDS) {
        for (const input of form.matchAll(new RegExp(`<input[^>]*name="${name}"[^>]*>`, "g"))) {
          if (!/\brequired\b/.test(input[0])) {
            problems.push(`${screen} asks for ${name} without requiring it, so the answer goes to a refusal instead of to a box.`);
          }
        }
      }
    }
    asked += 1;
  }
}

if (!asked) {
  problems.push("no screen was found behind any of those actions, which means this check is reading the wrong thing.");
} else if (!problems.length) {
  ok(`and all ${asked} screens behind them ask for both, and require both`);
}

// ── 4. and a request already satisfied is one click ──────────
//
// `decide_stage_request` closes a request whose client is already in the
// stage without ever reaching the move, so it reads neither field. A screen
// that asks for them anyway - and requires them, which step 3 insists on -
// makes two questions out of a close, about a placement that happened before
// the request was read. The answers go nowhere.
//
// Asked of the gate rather than of the file: the variable that decides whether
// the two fields are shown has to take account of where the client already is.
// A check that only looked for the comparison anywhere in the file would pass
// a screen that worked it out and then ignored it.
const REQUESTS = "app/(app)/clients/stage-board.tsx";
{
  const src = read(REQUESTS);
  const decls = new Map(
    [...src.matchAll(/\bconst\s+([A-Za-z0-9_]+)\s*=\s*([^;]+);/g)].map((m) => [m[1], m[2]]),
  );
  const gates = [...decls.entries()].filter(([, value]) => value.includes('"Job Placement"'));

  if (!gates.length) {
    problems.push(
      `${REQUESTS} has nothing deciding whether the Job Placement questions are asked, so whether a satisfied request is one click is unknown.`,
    );
  } else {
    // One level of expansion: the gate, plus whatever it names.
    const sameStage = /\brow\.stage\s*===?\s*row\.stage_request_to\b|\brow\.stage_request_to\s*===?\s*row\.stage\b/;
    for (const [name, value] of gates) {
      const expanded =
        value +
        [...value.matchAll(/\b([A-Za-z0-9_]+)\b/g)]
          .map((m) => decls.get(m[1]) ?? "")
          .join(" ");
      if (!sameStage.test(expanded)) {
        problems.push(
          `${REQUESTS} decides the Job Placement questions on "${name}" without asking where the client already is, so a request for the stage they are in asks for an employer and a start date to close it.`,
        );
      }
    }
    if (!problems.length) ok("and a request whose client is already in that stage closes in one click");
  }
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- EVERY DOOR INTO JOB PLACEMENT ASKS WHAT THE STAGE MEANS ---");
