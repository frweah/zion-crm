/**
 * One navigation at every width, and the Team bubble standing on none of it.
 *
 *   node scripts/check-bubble.mjs
 *
 * Two rules, both the owner's and both about the same corner of the screen.
 *
 * 6 November, morning: the bubble was `position: fixed; left: 16px`, which put
 * it inside the sidebar - on top of the chevron that narrows the sidebar, at
 * the sidebar's own foot. Which of the two you could press depended on the
 * stacking order, and at 64px wide the sidebar is narrower than the bubble, so
 * the bubble also hung over the page.
 *
 * 6 November, afternoon: "hide the sidebar; the bottom bar carries the hubs.
 * One place, not two." Below 760px both were on screen, offering the same
 * hubs twice.
 *
 * So this is arithmetic rather than a search for a string: the bubble's left
 * edge, in pixels, against the sidebar's width, in pixels, at every width the
 * layout has a rule for. A rule that reads `left: 16px` and a rule that reads
 * `left: calc(var(--side-narrow) + 16px)` are both just numbers once the
 * tokens are substituted, and one of them overlaps.
 *
 * Four states, because the sidebar has four widths:
 *
 *   wide, over 1100px and nobody has narrowed it     - 236px
 *   narrowed by choice, over 1100px                  -  64px
 *   under 1100px, where the width decides            -  64px
 *   under 760px, where the bottom bar carries them   -   0px, hidden
 *
 * and the bottom bar is the vertical half of the same question: it spans the
 * whole width, so on a phone the bubble has to clear its height.
 *
 * Each state asks its rules the way a browser does - the top-level rule, then
 * the 1100px one, then the 760px one, last value wins - rather than reading
 * one block and hoping the others agree. The first version read the phone's
 * bubble out of the 1100px block with a fallback, which was right by accident
 * and would have gone on being right after the phone's own rule changed.
 *
 * What it cannot ask: whether anything *else* is drawn bottom-left. If a
 * third floating control is added there one day, this check will say the
 * bubble is clear of the sidebar and be telling the truth about the wrong
 * question.
 */
import { readFile } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const css = await readFile(new URL("../app/globals.css", import.meta.url), "utf8");
const tokens = await readFile(new URL("../app/tokens.css", import.meta.url), "utf8");

/** A `--name: 236px;` declaration, as a number. */
function token(name) {
  const m = tokens.match(new RegExp(`--${name}:\\s*([\\d.]+)px`));
  return m ? Number(m[1]) : null;
}

const WIDE = token("side-wide");
const NARROW = token("side-narrow");
if (WIDE === null || NARROW === null) {
  fail("the sidebar's widths are not --side-wide and --side-narrow in tokens.css any more, so this check is measuring nothing");
}

/**
 * Every rule in the stylesheet, with the at-rule it sits inside.
 *
 * A character walk rather than one regular expression, because the first
 * version of this was a regex over `selector { body }` with a brace counter,
 * and `@keyframes` broke it: a nested block made the counter go negative and
 * every media query after that point read as top-level, so the check reported
 * the phone's rule as the desktop's and failed on its own fix.
 */
function rules() {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, " ");
  const found = [];
  const stack = [];
  let buffer = "";
  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];
    if (ch === "{") {
      stack.push(buffer.trim());
      buffer = "";
    } else if (ch === "}") {
      const head = stack.pop() ?? "";
      // A block whose own text held declarations is a rule; a block that only
      // held other blocks is an at-rule, and its children were recorded as
      // they closed.
      if (buffer.includes(":")) {
        found.push({
          selector: head,
          // The at-rule this sits in, or null at the top level. Only one deep
          // is ever needed here and only one deep is ever written.
          at: stack.length ? stack[stack.length - 1].replace(/^@media\s*/, "") : null,
          body: buffer,
        });
      }
      buffer = "";
    } else {
      buffer += ch;
    }
  }
  return found;
}

const ALL = rules();

/** The last value a property is given for a selector matching `test`. */
function valueOf(query, test, prop) {
  let value = null;
  for (const r of ALL) {
    if ((r.at ?? null) !== query) continue;
    if (!r.selector.split(",").some((one) => test.test(one.trim()))) continue;
    const m = r.body.match(new RegExp(`(?:^|[;\\s])${prop}:\\s*([^;]+)`));
    if (m) value = m[1].trim();
  }
  return value;
}

/** The same, read through every block that applies at one width. */
function cascade(queries, test, prop) {
  let value = null;
  for (const q of queries) {
    const got = valueOf(q, test, prop);
    if (got !== null) value = got;
  }
  return value;
}

/** `calc(var(--side-wide) + 16px)` → 252. `16px` → 16. */
function px(value) {
  if (value === null) return null;
  const substituted = value
    .replace(/var\(--side-wide\)/g, `${WIDE}px`)
    .replace(/var\(--side-narrow\)/g, `${NARROW}px`)
    // env() is 0 on a desktop and positive on a phone with a home bar, so the
    // smallest it can be is the honest number to check against.
    .replace(/env\([^)]*\)/g, "0px");
  const inner = substituted.replace(/^calc\(|\)$/g, "");
  const terms = inner.match(/[+-]?\s*[\d.]+px/g);
  if (!terms) return null;
  return terms.reduce((sum, t) => sum + Number(t.replace(/\s|px/g, "")), 0);
}

const TOP = [null];
const TABLET = [null, "(max-width: 1099px)"];
const PHONE = [null, "(max-width: 1099px)", "(max-width: 760px)"];

// ── the four states ──────────────────────────────────────────
const STATES = [
  {
    what: "wide, with the sidebar in full",
    at: TOP,
    width: WIDE,
    bubble: /^\.team-bubble$/,
    pane: /^\.team-pane\.compact$/,
  },
  {
    what: "narrowed to icons by choice",
    at: TOP,
    width: NARROW,
    bubble: /^\.shell\.side-narrow \.team-bubble$/,
    pane: /^\.shell\.side-narrow \.team-pane\.compact$/,
  },
  {
    what: "under 1100px, where the width decides",
    at: TABLET,
    width: NARROW,
    bubble: /^\.team-bubble$/,
    pane: /^\.team-pane\.compact$/,
  },
  {
    what: "under 760px, where the bottom bar carries the hubs",
    at: PHONE,
    width: NARROW,
    bubble: /^\.team-bubble$/,
    pane: /^\.team-pane\.compact$/,
  },
];

for (const s of STATES) {
  s.sideShown = cascade(s.at, /^\.side$/, "display") !== "none";
  s.barShown = cascade(s.at, /^\.bottom-bar$/, "display") !== "none";
  s.side = s.sideShown ? s.width : 0;
  s.left = px(cascade(s.at, s.bubble, "left"));
  s.paneLeft = px(cascade(s.at, s.pane, "left"));
}

// ── one place, not two ───────────────────────────────────────
for (const s of STATES) {
  if (s.sideShown && s.barShown) {
    fail(`${s.what}: the sidebar and the bottom bar are both on screen, offering the same hubs twice`);
  } else if (!s.sideShown && !s.barShown) {
    fail(`${s.what}: neither the sidebar nor the bottom bar is on screen, so there is no way to any hub`);
  }
}
if (!problems.length) {
  ok("the sidebar carries the hubs, or the bottom bar does, at all four widths");
}

// ── and the bubble stands on neither ─────────────────────────
const before = problems.length;
for (const s of STATES) {
  if (s.left === null) {
    fail(`nothing says where the bubble sits ${s.what}, so it falls back to a rule written for another width`);
    continue;
  }
  if (s.left < s.side) {
    fail(
      `${s.what}: the bubble's left edge is ${s.left}px and the sidebar is ${s.side}px wide, ` +
        `so ${s.side - s.left}px of it is over the sidebar - which is where the chevron that narrows the sidebar is`,
    );
  } else if (s.paneLeft !== null && s.paneLeft < s.side) {
    fail(`${s.what}: the chat window's left edge is ${s.paneLeft}px and the sidebar is ${s.side}px wide`);
  }
}
if (problems.length === before) {
  ok(`the bubble and its window clear the sidebar at all ${STATES.length} widths it has`);
}

// ── and the chevron is not offered where it does nothing ─────
//
// Under 1100px the sidebar's width is decided by the screen, so the control
// that offers to change it is hidden. It was hidden by name - `.side-toggle` -
// and the button renders as `.side-chevron`, so for five weeks the rule hid
// nothing and the chevron sat under the bubble.
const toggle = await readFile(new URL("../app/(app)/sidebar-toggle.tsx", import.meta.url), "utf8");
const klass = toggle.match(/className="([^"]*)"/)?.[1];
if (!klass) {
  fail("the sidebar toggle has no class, so no stylesheet can hide it");
} else if (valueOf("(max-width: 1099px)", new RegExp(`^\\.${klass}$`), "display") !== "none") {
  fail(
    `.${klass} is the class the sidebar's own control renders with and nothing hides it under 1100px, ` +
      `where the width is not its to decide`,
  );
} else {
  ok(`the sidebar's control is hidden under 1100px, by the class it actually renders with`);
}

// ── the bubble clears the bottom bar on a phone ──────────────
const barTop = px(valueOf("(max-width: 760px)", /^\.bottom-bar$/, "padding"));
const itemHeight = px(valueOf("(max-width: 760px)", /^\.bottom-item$/, "min-height"));
const bubbleBottom = px(cascade(PHONE, /^\.team-bubble$/, "bottom"));
if (bubbleBottom === null) {
  fail("nothing lifts the bubble above the bottom bar on a phone");
} else if (itemHeight === null) {
  fail("the bottom bar's items have no height, so there is nothing to clear");
} else {
  // The bar is its padding plus the tallest thing in it. `padding` here is the
  // shorthand, so px() has summed its parts rather than read one of them -
  // which is larger than the truth, and erring that way is the right
  // direction for a clearance check.
  const bar = itemHeight + (barTop ?? 0);
  if (bubbleBottom < bar) {
    fail(
      `the bubble sits ${bubbleBottom}px up and the bottom bar is about ${bar}px tall, so they overlap on a phone`,
    );
  } else {
    ok(`the bubble clears the bottom bar by about ${bubbleBottom - bar}px on a phone`);
  }
}

// ── and it is there to be pressed where it is the only way ───
//
// Team is in the sidebar and in no hub, so with the sidebar hidden the bubble
// is the only way to Team chat on a phone - including for somebody who turned
// it off, who would otherwise have no way to the screen that turns it back on.
const bubbleSource = await readFile(new URL("../app/(app)/team-bubble.tsx", import.meta.url), "utf8");
if (!/max-width:\s*760px/.test(bubbleSource)) {
  fail(
    "the Team bubble does not know about the width the sidebar is hidden at, so turning it off leaves a phone " +
      "with no way to Team chat and no way to the setting",
  );
} else if (!/off\s*&&\s*!phone/.test(bubbleSource)) {
  fail("the Team bubble is hidden on a phone when it is turned off, and on a phone it is the only way in");
} else {
  ok("the bubble stays on a phone whatever the setting says, because there it is the only way to Team chat");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- ONE NAVIGATION, AND THE BUBBLE STANDS ON NOTHING ---");
