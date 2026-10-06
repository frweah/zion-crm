/**
 * Label · number · button (Design language, §2).
 *
 *   node --experimental-strip-types scripts/check-words.mjs
 *
 * The standard says explanations live in the one-time hint and the knowledge
 * base, never on the working screen, and that an empty state is one sentence.
 * Both are easy to agree with and easy to lose: a paragraph gets added to
 * explain a confusing control, the control stays confusing, and six months
 * later every screen has three paragraphs nobody reads.
 *
 * So the rule is checked rather than remembered:
 *
 *   An empty state is one sentence. Two sentences means the screen is
 *   apologising.
 *
 *   A line of explanation on a working screen is short. Anything longer is a
 *   hint, a knowledge-base article, or a sign the screen needs changing.
 *
 * What is deliberately not counted: the hint bar itself, the knowledge base,
 * the onboarding walkthrough and the policy screens, which exist to explain
 * things; and anything inside a comment.
 */
import { readdir, readFile } from "node:fs/promises";

const APP = new URL("../app/", import.meta.url);
const problems = [];

/**
 * Screens whose job is to explain, and the one group the standard leaves
 * alone: "Billing, authorizations, forms and warrants stay as they are for
 * now" (Design language, §4). Judging them by a rule the brief exempts them
 * from would be rewriting what the owner asked to leave untouched.
 */
const EXPLAINERS = [
  "/billing/",
  "pending-authorizations",
  "hint-bar.tsx",
  "/sops/",
  "/paperwork/",
  "/login/",
  "/set-password/",
  "/auth/",
  "/admin/settings-hub/",
  "forms-and-checklists",
];

const EMPTY_SENTENCES = 1;
const SUB_LIMIT = 200;

async function files(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
    if (entry.isDirectory()) out.push(...(await files(url)));
    else if (entry.name.endsWith(".tsx")) out.push(url);
  }
  return out;
}

const rel = (url) => decodeURIComponent(url.pathname).split("/zion-crm/")[1] ?? url.pathname;

/** Text of an element with this class, as written in the source. */
function* textOf(src, className) {
  const open = new RegExp(`className="[^"]*\\b${className}\\b[^"]*"[^>]*>`, "g");
  for (const m of src.matchAll(open)) {
    const from = m.index + m[0].length;
    const to = src.indexOf("<", from);
    if (to === -1) continue;
    const raw = src.slice(from, to);
    // Only prose somebody wrote on the screen. Anything with an expression in
    // it is assembled at runtime, and what this pulls out of one is a
    // fragment of code rather than a sentence to judge.
    if (raw.includes("{")) continue;
    const text = raw
      .replace(/&apos;|&rsquo;/g, "'")
      .replace(/&quot;|&ldquo;|&rdquo;/g, '"')
      .replace(/\s+/g, " ")
      .trim();
    if (text) yield text;
  }
}

const sentences = (text) => (text.match(/[.!?](\s|$)/g) ?? []).length;

for (const url of await files(APP)) {
  const path = rel(url);
  if (EXPLAINERS.some((e) => path.includes(e))) continue;
  const src = await readFile(url, "utf8");

  for (const text of textOf(src, "empty")) {
    if (sentences(text) > EMPTY_SENTENCES) {
      problems.push(`${path}: an empty state is one sentence — "${text.slice(0, 90)}…"`);
    }
  }

  for (const text of textOf(src, "sub")) {
    if (text.length > SUB_LIMIT) {
      problems.push(
        `${path}: ${text.length} characters of explanation on a working screen — "${text.slice(0, 70)}…". It belongs in the hint or the knowledge base.`,
      );
    }
  }
}

if (problems.length) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log("  ok  every empty state is one sentence, and no screen explains itself at length");
console.log("");
console.log("--- WORDS VERIFIED ---");
