/**
 * The clock is on every screen.
 *
 *   node scripts/check-clock-button.mjs
 *
 * "On every page" is the kind of promise that is true the day it is made and
 * slightly false a month later, one screen at a time. So it is not checked by
 * counting screens: it is checked by insisting the button is mounted **once,
 * in the shared layout**, which is the only arrangement under which adding a
 * screen cannot leave it out.
 *
 * The same reasoning as `check-nav`, which was once satisfied by a hub merely
 * having a page when the rule was whether anybody could open one. Asking "is
 * it in the layout" answers the rule; asking "is it on these 48 screens"
 * answers a roster that goes stale.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const LAYOUT = join("app", "(app)", "layout.tsx");
const BUTTON = join("app", "(app)", "clock-button.tsx");

const layout = readFileSync(LAYOUT, "utf8");
const button = readFileSync(BUTTON, "utf8");

// ── it is in the layout ──────────────────────────────────────

if (!/<ClockButton\b/.test(layout)) {
  fail(`${LAYOUT} does not mount <ClockButton>, so the clock is not on every screen`);
} else if (!/from "\.\/clock-button"/.test(layout)) {
  fail(`${LAYOUT} mounts something called ClockButton that is not ./clock-button`);
} else {
  ok("the clock is mounted in the shared layout, so every screen under it has one");
}

// The layout has to give it the open session and today's figure, or it renders
// "Clock in" at six in the evening to somebody who has been on the clock since
// eight.
for (const prop of ["startedAt", "onBreakSince", "breakSeconds", "todayHours"]) {
  if (!new RegExp(`${prop}=`).test(layout)) {
    fail(`${LAYOUT} mounts the clock without ${prop}, so it cannot show the state it is in`);
  }
}
if (!/work_session_timers/.test(layout)) {
  fail(`${LAYOUT} does not read the open session, so the clock cannot know there is one`);
} else if (!/my_hours_summary/.test(layout)) {
  fail(`${LAYOUT} does not read today's hours, so the running figure starts from nothing`);
} else {
  ok("and the layout reads the open session and today's hours to give it");
}

// ── and nowhere else ─────────────────────────────────────────
//
// A second copy is how two clocks come to disagree on one screen.

function sources(dir, found = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== ".next") sources(path, found);
    } else if (name.endsWith(".tsx")) {
      found.push(path);
    }
  }
  return found;
}

const mounts = sources("app").filter(
  (p) => p !== LAYOUT && p !== BUTTON && /<ClockButton\b/.test(readFileSync(p, "utf8")),
);
if (mounts.length > 0) {
  fail(`the clock is also mounted in ${mounts.join(", ")} — two clocks on one screen will disagree`);
} else {
  ok("and it is mounted nowhere else, so no screen shows two");
}

// ── the four states, and the four actions ────────────────────
//
// Read off the component rather than rendered: what matters is that none of
// them has been dropped, and a missing action is a person who cannot stop the
// clock from the screen they are on.

for (const [what, pattern] of [
  ["clock in", /clockIn\b/],
  ["start a break", /startBreak\b/],
  ["end a break", /endBreak\b/],
]) {
  if (!pattern.test(button)) fail(`${BUTTON} offers no way to ${what}`);
}

/*
 * Clocking out, which since 0353 asks what the day was.
 *
 * The button no longer calls the action itself - it opens the panel that
 * does - so looking for `clockOut` in this one file would be looking for the
 * old arrangement rather than for the rule. The rule is that somebody can
 * stop the clock from the header, and it now takes two files to be true: the
 * button opens the panel, and the panel clocks out.
 *
 * Both halves are asserted, and so is the way past it. A button that opens
 * nothing, a panel that asks the question and never stops the clock, and a
 * panel with no way through without answering each fail here.
 */
const SUMMARY = join("app", "(app)", "clock-summary.tsx");
let summary = "";
try {
  summary = readFileSync(SUMMARY, "utf8");
} catch {
  summary = "";
}
if (/clockOut\b/.test(button)) {
  ok("the header clocks out directly");
} else if (!/<ClockSummary\b/.test(button)) {
  fail(`${BUTTON} offers no way to clock out: it neither calls clockOut nor opens <ClockSummary>`);
} else if (summary === "") {
  fail(`${BUTTON} opens <ClockSummary> and ${SUMMARY} is not there`);
} else if (!/clockOutWith\b/.test(summary)) {
  fail(`${SUMMARY} asks what the day was and never clocks anybody out`);
} else if (!/without saying/i.test(summary)) {
  fail(
    `${SUMMARY} asks what the day was with no way past it - the account is not required (owner, 14 Nov 2026)`,
  );
} else {
  ok("clocking out asks what the day was, and offers a way past it");
}

// Clocked out, clocked in, and on a break each have to look different, or the
// button is decoration.
if (!/startedAt\s*\)/.test(button) && !/!startedAt/.test(button)) {
  fail(`${BUTTON} does not distinguish being clocked out from being clocked in`);
} else if (!/onBreakSince\s*\?/.test(button)) {
  fail(`${BUTTON} does not show a break differently from working`);
} else if (problems.length === 0) {
  ok("clocked out, clocked in and on a break each read differently, with their own actions");
}

// ── and it survives a phone ──────────────────────────────────

const css = readFileSync(join("app", "globals.css"), "utf8");
if (!/\.clock-button\s*\{/.test(css)) {
  fail("app/globals.css has no .clock-button rule, so it is laid out by accident");
} else if (!/@media \(max-width: 700px\)[\s\S]{0,400}\.clock-button/.test(css)) {
  fail("app/globals.css does not say what the clock does at phone width");
} else {
  ok("and it has a phone-width rule rather than being laid out by accident");
}

if (problems.length) {
  console.error("\nFAILED");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- CLOCK BUTTON VERIFIED ---");
