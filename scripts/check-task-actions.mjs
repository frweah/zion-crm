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

// ── 3. Today offers both, by name ────────────────────────────
const todayTask = await readFile(new URL("../app/(app)/dashboard/dashboard-task.tsx", import.meta.url), "utf8");
const control = await readFile(new URL("../app/(app)/tasks/task-actions.tsx", import.meta.url), "utf8");
// Comments out first. The house style is long comments explaining why, and
// the first version of this read the comment saying the circle was replaced
// as the circle itself - a check that fails on its own fix.
const rendered = todayTask.replace(/\{\/\*[\s\S]*?\*\/\}/g, "").replace(/^\s*\/\/.*$/gm, "");
if (!/TaskActions/.test(todayTask)) {
  fail("Today's tasks carry neither action");
} else if (!/Mark complete/.test(control) || !/>\s*Remove\s*</.test(control)) {
  fail("the two actions are not named on the button that performs them");
} else if (/[○✓]/.test(rendered)) {
  fail("Today still marks a task done with a drawn circle, which says nothing to anybody not using a screen reader");
} else {
  ok("Today names both actions: Mark complete, and Remove");
}

// ── 4. a removed task can still be found ─────────────────────
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
