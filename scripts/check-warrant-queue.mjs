/**
 * Needs review counts the questions, not the readings.
 *
 *   node scripts/check-warrant-queue.mjs
 *
 * Admin → Warrants counted every `warrant_lines` row whose status was "Needs
 * review" - 102 of them for $129,505 on 19 November 2026, when 7 lines needed
 * a person. The rest were the same stubs scanned more than once, and money the
 * practice had written down months earlier that nothing had thought to ask
 * about.
 *
 * `warrant_review_queue` (0376) is the question: one row per line on the stub,
 * and only the ones no payment on file accounts for. The database holds that
 * rule and `supabase/verify_warrant_queue.sql` asserts it. This is about the
 * screen asking it, rather than going back to counting rows.
 *
 * What it asks:
 *
 *   1. the section reads the queue, and does not read the lines table for it;
 *   2. the tile counts the queue rather than the line statuses;
 *   3. the list of pages says what a page has outstanding now, rather than the
 *      status the reader stored - a page reading "Needs review" beside a count
 *      of nothing is the screen contradicting itself;
 *   4. and a figure two scans disagree about is not filled in for somebody.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const read = (p) => readFileSync(path.join(root, p), "utf8");

const PAGE = "app/(app)/admin/warrants/page.tsx";
const SECTION = "app/(app)/admin/warrants/review-section.tsx";
const ITEM = "app/(app)/admin/warrants/warrant-review.tsx";

// ── 1. the section asks the queue ────────────────────────────
const section = read(SECTION);
if (!/\.rpc\("warrant_review_queue"\)/.test(section)) {
  problems.push(`${SECTION} does not ask warrant_review_queue, so the queue is back to being a count of rows.`);
} else if (/\.from\("warrant_lines"\)/.test(section) || /"Needs review"/.test(section)) {
  problems.push(
    `${SECTION} reads the lines table or the "Needs review" status itself. The queue is one row per stub line and only the unanswered ones; a second source disagrees with it the day a stub is scanned twice.`,
  );
} else {
  ok("the review section asks the queue, and nothing else");
}

// ── 2. the tile counts the queue ─────────────────────────────
//
// Bounded to the tile: the <small> says what the figure is, so the figure is
// the expression in the <div className="stat"> above it. A check that merely
// looked for `queue.length` anywhere in the file would pass a page that used
// it for the heading and still counted rows here.
const page = read(PAGE);
const tileEnd = page.indexOf("<small>lines to review</small>");
const tileStart = tileEnd < 0 ? -1 : page.lastIndexOf('className="stat"', tileEnd);
const tile = tileStart < 0 ? "" : page.slice(tileStart, tileEnd);
if (!tile) {
  problems.push(`${PAGE} has no "lines to review" tile this check can read, so what it counts is unknown.`);
} else if (/count\(/.test(tile)) {
  problems.push(
    `${PAGE} counts line statuses in the "lines to review" tile. 102 readings were 62 stub lines and 7 questions; counting rows is what made the figure meaningless.`,
  );
} else if (!/queue\.length/.test(tile)) {
  problems.push(`${PAGE} counts something other than the queue in the "lines to review" tile: ${tile.replace(/\s+/g, " ").trim()}`);
} else {
  ok("and the tile counts the queue, so the figure and the list cannot disagree");
}

// ── 3. a page says what it has outstanding ───────────────────
if (!/const open = lines\.some\(\(l\) => openLines\.has\(l\.id\)\)/.test(page)) {
  problems.push(
    `${PAGE} no longer works out which pages hold a question, so the list of pages can read "Needs review" beside a count of nothing.`,
  );
} else if (!/\{says\}/.test(page) || /\{p\.status\}/.test(page)) {
  problems.push(`${PAGE} prints the stored page status rather than what the page has outstanding now.`);
} else {
  ok("a page in the list says what it still has outstanding");
}

// ── 4. a disputed figure is nobody's default ─────────────────
const item = read(ITEM);
const amount = item.match(/<input name="amount"[^>]*>/);
if (!amount) {
  problems.push(`${ITEM} has no amount input this check can read, so what it offers is unknown.`);
} else if (/read_as/.test(amount[0])) {
  problems.push(
    `${ITEM} fills the amount in from the scans' readings. Where two scans disagree there is no figure to offer, and offering one is how a number nobody checked goes on the books: ${amount[0]}`,
  );
} else if (!/line\.amount/.test(amount[0])) {
  problems.push(`${ITEM} does not offer the agreed amount at all: ${amount[0]}`);
} else {
  ok("and an amount the scans disagree about is left for a person to type");
}

if (problems.length) {
  console.error(`\n${problems.length} problem(s):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- NEEDS REVIEW COUNTS THE QUESTIONS ---");
