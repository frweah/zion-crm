/**
 * When a template may fill the note box.
 *
 *   node --experimental-strip-types scripts/check-note-template.mjs
 *
 * One rule matters more than the rest of 10.2 put together: text somebody
 * typed is never replaced. The failure mode is silent and unrecoverable — a
 * counselor writes up a coaching session, notices the type is wrong, changes
 * it, and the writing is gone with nothing to undo. Most of what follows is
 * that one rule from several directions.
 */
import { onTypeChange, isOnlyTemplate } from "../lib/note-template.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const COACHING = "Where, and how long:\n\nWhat was worked on:\n\nHow the client did:\n";
const CALL = "Who I spoke to:\n\nWhat it was about:\n";

// ── an empty box gets the headings ───────────────────────────
const first = onTypeChange("", null, COACHING);
if (first.action !== "fill" || first.body !== COACHING) {
  fail(`an empty box was not filled — got "${first.action}"`);
} else {
  ok("an empty box gets the headings for the type chosen");
}

// Whitespace is empty. Somebody who clicked into the box and pressed return
// has not written anything.
if (onTypeChange("\n  \n", null, COACHING).action !== "fill") {
  fail("a box holding only whitespace was treated as somebody's writing");
} else {
  ok("a box holding only blank lines counts as empty");
}

// ── writing is never replaced ────────────────────────────────
const typed = "Met Jordan at the store at 9. He handled the register alone for the first time.";
const guarded = onTypeChange(typed, null, COACHING);
if (guarded.action !== "keep") {
  fail(`typed text was replaced — got "${guarded.action}"`);
} else if (guarded.offer !== COACHING) {
  fail("the new headings were not offered as a choice");
} else {
  ok("text somebody typed is left alone, and the headings are offered instead");
}

// The dangerous case: they were given headings, filled them in, then changed
// the type. What is in the box no longer matches what was put there, so it is
// theirs.
const filledIn = COACHING.replace("What was worked on:", "What was worked on: the register");
if (onTypeChange(filledIn, COACHING, CALL).action !== "keep") {
  fail("headings that had been answered were overwritten by another type's");
} else {
  ok("headings somebody has answered are their writing, and are kept");
}

// The safe case, which is the whole reason the applied template is tracked:
// they chose the wrong type, typed nothing, and changed it. Nothing is lost,
// so asking would be noise.
const swapped = onTypeChange(COACHING, COACHING, CALL);
if (swapped.action !== "fill" || swapped.body !== CALL) {
  fail("changing the type before typing anything did not swap the headings");
} else {
  ok("changing the type before writing anything simply swaps the headings");
}

// ── a type with no template empties the box ──────────────────
const cleared = onTypeChange(COACHING, COACHING, "");
if (cleared.action !== "clear" || cleared.body !== "") {
  fail("switching to a type with no headings left the previous type's behind");
} else {
  ok("a type with no headings leaves an empty box, not the last type's questions");
}

// And that must not empty a box with writing in it.
if (onTypeChange(typed, null, "").action !== "keep") {
  fail("switching to a type with no headings destroyed somebody's writing");
} else {
  ok("— unless there is writing in it, which survives that too");
}

// ── the skeleton on its own is not a note ────────────────────
if (!isOnlyTemplate(COACHING, COACHING)) {
  fail("a note that is nothing but the headings was accepted as written");
} else {
  ok("a note that is only the headings is recognised as unwritten");
}

// Tabbing through the headings and adding nothing leaves trailing spaces.
const whitespaced = COACHING.split("\n").map((l) => (l ? l + "   " : l)).join("\n") + "\n\n";
if (!isOnlyTemplate(whitespaced, COACHING)) {
  fail("headings with trailing spaces passed as a written note");
} else {
  ok("trailing spaces and blank lines are not answers");
}

// One real sentence makes it a note. This is the line that must not be drawn
// too strictly: a short note is still a note, and refusing it would teach
// people to pad.
if (isOnlyTemplate(COACHING + "He did well.", COACHING)) {
  fail("a note with something written in it was refused");
} else {
  ok("one sentence of somebody's own makes it a note");
}

// A note written with no template in play is never second-guessed.
if (isOnlyTemplate("Called, no answer.", null)) {
  fail("a note written without a template was judged against one");
} else {
  ok("a note written without a template is never measured against one");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- NOTE TEMPLATES VERIFIED ---");
