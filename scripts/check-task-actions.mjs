/**
 * The two actions on a task, where no database is needed (0297).
 *
 *   node scripts/check-task-actions.mjs
 *
 * One rule carries the whole design, and it is the kind nobody would think to
 * check: **a list of unfinished tasks asks for `status = 'Open'`, never for
 * "not Done".**
 *
 * A third status was chosen over a `removed_at` column precisely because every
 * list already asks the first way, so Removed drops out of all of them without
 * a line being changed. The day somebody writes `.neq("status", "Done")` - a
 * reasonable thing to write - removed tasks come back on Today, on My day, in
 * the notifications and in the nightly digest at once, and nothing fails.
 *
 * The rest of what is asked here is the part a screen decides on its own: that
 * the remover is not a value the browser sends, and that a removed task can
 * still be found by somebody wondering where it went.
 */
import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const problems = [];
const fail = (said) => problems.push(said);
const ok = (said) => console.log(`  ok  ${said}`);

// Forward slashes, never path.join: a path-keyed comparison built with it
// passes on Windows and matches nothing on Linux.
const ROOT = fileURLToPath(new URL("../", import.meta.url)).split("\\").join("/");
const rel = (url) => fileURLToPath(url).split("\\").join("/").slice(ROOT.length);

async function* sources(dir, exts) {
  for (const e of await readdir(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === ".next") continue;
    const at = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
    if (e.isDirectory()) yield* sources(at, exts);
    else if (exts.some((x) => e.name.endsWith(x))) yield at;
  }
}

// ── 1. nothing asks for "not Done" ───────────────────────────
//
// Both spellings: the client library's `.neq("status", "Done")` and SQL's
// `status <> 'Done'`. The file has to be about tasks for this to mean
// anything - authorizations and reports have statuses of their own, and
// "not Done" is a fair thing to ask of those.
const notDone = [];
for (const dir of ["app/", "lib/"]) {
  for await (const file of sources(new URL(`../${dir}`, import.meta.url), [".ts", ".tsx"])) {
    const text = await readFile(file, "utf8");
    if (!/\.from\("tasks"\)/.test(text)) continue;
    for (const m of text.matchAll(/\.(neq|not)\(\s*"status"\s*,\s*(?:"neq"\s*,\s*)?"Done"/g)) {
      notDone.push(`${rel(file)}:${text.slice(0, m.index).split("\n").length}`);
    }
  }
}
for await (const file of sources(new URL("../supabase/", import.meta.url), [".sql"])) {
  const text = await readFile(file, "utf8");
  for (const m of text.matchAll(/tasks[\s\S]{0,400}?status\s*(?:<>|!=|not\s+in)\s*\(?\s*'Done'/gi)) {
    notDone.push(`${rel(file)}:${text.slice(0, m.index).split("\n").length}`);
  }
}
if (notDone.length) {
  fail(
    `${notDone.join(", ")} asks for tasks that are not Done, which is also every task somebody took off the list - ` +
      `ask for status = 'Open' instead`,
  );
} else {
  ok("every list of unfinished tasks asks for Open, so a removed one is out of all of them");
}

// The same question, the other way round: if nothing in the system asks for
// Open either, this check is asserting nothing at all.
let asksOpen = 0;
for (const dir of ["app/", "lib/"]) {
  for await (const file of sources(new URL(`../${dir}`, import.meta.url), [".ts", ".tsx"])) {
    const text = await readFile(file, "utf8");
    if (!/\.from\("tasks"\)/.test(text)) continue;
    asksOpen += (text.match(/\.eq\(\s*"status"\s*,\s*"Open"\s*\)/g) ?? []).length;
  }
}
if (asksOpen === 0) {
  fail("no screen asks for tasks that are Open, so the question above is about nothing");
} else {
  ok(`${asksOpen} task lists ask for Open by name`);
}

// ── 2. the remover is not a value the browser sends ──────────
const actions = await readFile(new URL("../app/(app)/tasks/actions.ts", import.meta.url), "utf8");
const removeFn = actions.slice(actions.indexOf("export async function removeTask"));
const removeBody = removeFn.slice(0, removeFn.indexOf("\n}") + 2);
if (!removeBody || !/status: "Removed"/.test(removeBody)) {
  fail("nothing takes a task off the list");
} else if (/removed_by/.test(removeBody)) {
  fail("the action sets removed_by itself, so whoever is removing it can name somebody else");
} else if (!/removed_reason: reason \|\| null/.test(removeBody)) {
  fail("an empty reason box is stored as an empty string, which reads as a reason that was given");
} else {
  ok("who removed a task is written by the database, not sent by the screen");
}

// ── 3. the actions are named on the control that performs them ──
const CONTROL = "app/(app)/tasks/task-actions.tsx";
const control = await readFile(new URL(`../${CONTROL}`, import.meta.url), "utf8");
if (!/Mark complete/.test(control) || !/>\s*Remove\s*</.test(control)) {
  fail("the two actions are not named on the button that performs them");
} else {
  ok("the control names both actions: Mark complete, and Remove");
}

// ── 4. and it is the only control there is ───────────────────
//
// The owner, 6 Nov 2026: "anywhere a task row renders uses the same control."
// It was two controls and two actions: Today and Tasks had this pair, and the
// client's record had a button drawn as a circle, with no way to take a task
// off the list and a server action of its own writing the same column. My day
// and the lists behind the Home counters had neither action at all.
//
// Said as two rules, because "the same control" is both of these:
//
//   nothing else draws a task's actions - no second pair of buttons, and no
//   glyph standing in for a word;
//
//   nothing else writes a task's status - one module, so a second control
//   cannot be wired up without this failing first.
const strip = (t) => t.replace(/\{\/\*[\s\S]*?\*\/\}/g, "").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");

const drawn = [];
const glyphs = [];
for await (const file of sources(new URL("../app/", import.meta.url), [".tsx"])) {
  if (rel(file) === CONTROL) continue;
  const text = strip(await readFile(file, "utf8"));
  if (/>\s*Mark (complete|done)\s*</.test(text) || /aria-label=["'](Mark done|Mark complete|Reopen)["']/.test(text)) {
    drawn.push(rel(file));
  }
  // A circle or a tick as the whole of a *button's* label. A tick in a chip
  // is a state, not a control: it says "this one is done" beside the ones
  // that are not, which is information rather than a word withheld. The first
  // version of this rule failed the staff checklist's state chip and had to
  // be told the difference. The portal has its own vocabulary and is not a
  // task list.
  const buttons = text.match(/<button[\s\S]*?<\/button>/g) ?? [];
  if (buttons.some((b) => /[○✓]/.test(b.replace(/<[^>]*>/g, ""))) && !rel(file).startsWith("app/portal/")) {
    glyphs.push(rel(file));
  }
}
if (drawn.length) {
  fail(`${drawn.join(", ")} draws a task's actions itself instead of using the one control`);
} else if (glyphs.length) {
  fail(
    `${glyphs.join(", ")} marks something done with a drawn circle or tick, which says nothing to anybody not using a screen reader`,
  );
} else {
  ok("no screen draws a task's actions itself, and none of them stands a glyph in for a word");
}

const writers = [];
for (const dir of ["app/", "lib/"]) {
  for await (const file of sources(new URL(`../${dir}`, import.meta.url), [".ts", ".tsx"])) {
    if (rel(file) === "app/(app)/tasks/actions.ts") continue;
    const text = await readFile(file, "utf8");
    // `.from("tasks")` and an `.update({ ... status ... })` within reach of
    // it. The window matters: a file may read tasks in one place and update
    // something else in another.
    if (/\.from\("tasks"\)[\s\S]{0,200}?\.update\(\{[\s\S]{0,200}?status:/.test(text)) {
      writers.push(rel(file));
    }
  }
}
if (writers.length) {
  fail(
    `${writers.join(", ")} writes a task's status as well, so there are two answers to what "complete" does`,
  );
} else {
  ok("one module writes a task's status, so there is one answer to what the actions do");
}

// ── 5. every screen that lists tasks carries them ────────────
//
// The screens are worked out rather than listed: a .tsx under app/ that reads
// tasks with their titles is a screen showing tasks, and one that imports
// lib/needs is showing whatever the Home counters count, which includes them.
// Then the control has to be reachable from it - directly or through a
// component it imports, because the client's record reaches it three files
// down.
//
// What this cannot see: a screen that is handed task rows by a parent and
// reads nothing itself. There is none today; the import walk below would have
// to start from the other end to be sure of it.
const screens = [];
for await (const file of sources(new URL("../app/", import.meta.url), [".tsx"])) {
  const text = await readFile(file, "utf8");
  const listsTasks = /\.from\("tasks"\)[\s\S]{0,200}?title/.test(text);
  const listsNeeds = /from "@\/lib\/needs"/.test(text);
  if (listsTasks || listsNeeds) screens.push(rel(file));
}

/** Everything a file imports from inside the project, followed through. */
async function reaches(start, what, seen = new Set()) {
  if (seen.has(start)) return false;
  seen.add(start);
  let text;
  try {
    text = await readFile(new URL(`../${start}`, import.meta.url), "utf8");
  } catch {
    return false;
  }
  if (text.includes(what)) return true;
  const here = start.slice(0, start.lastIndexOf("/"));
  for (const m of text.matchAll(/from "(\.[^"]+|@\/[^"]+)"/g)) {
    const spec = m[1];
    let base;
    if (spec.startsWith("@/")) base = spec.slice(2);
    else {
      // Resolve "../tasks/task-actions" against the importing file's folder,
      // with forward slashes throughout - path.join spells them differently
      // on Linux and this comparison is path-keyed.
      const parts = (here + "/" + spec).split("/");
      const out = [];
      for (const part of parts) {
        if (part === "." || part === "") continue;
        if (part === "..") out.pop();
        else out.push(part);
      }
      base = out.join("/");
    }
    for (const ext of [".tsx", ".ts"]) {
      if (await reaches(base + ext, what, seen)) return true;
    }
  }
  return false;
}

const without = [];
for (const screen of screens) {
  if (!(await reaches(screen, "TaskActions"))) without.push(screen);
}
if (!screens.length) {
  fail("no screen appears to list tasks at all, so this question is about nothing");
} else if (without.length) {
  fail(
    `${without.join(", ")} lists tasks and offers neither action, so a task finished there has to be found again somewhere else`,
  );
} else {
  ok(`all ${screens.length} screens that list tasks carry the same two actions`);
}

// ── 6. a removed task can still be found ─────────────────────
const view = await readFile(new URL("../app/(app)/tasks/tasks-view.tsx", import.meta.url), "utf8");
if (!/removed_by_name/.test(view)) {
  fail("Tasks never shows who took a task off the list, so a removal is a disappearance");
} else if (!/TaskRestore/.test(view)) {
  fail("a task taken off the list by mistake cannot be put back");
} else {
  ok("a removed task is still on Tasks, with who took it off and a way to put it back");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- THE TWO TASK ACTIONS VERIFIED ---");
