/**
 * Every kind the activity stream can emit has a chip to be seen under.
 *
 * `client_activity` is a union of a dozen branches, each labelling its rows
 * with a kind, and the Activity tab builds its filter from `ACTIVITY_KINDS`.
 * A branch added to the view without a kind added to that list is rows that
 * exist, are counted in "All", and can never be filtered to - which is the
 * quiet half of being invisible.
 *
 * It reads the migrations rather than the database, because prebuild runs
 * inside the deployment and has no credentials. That means it can only see
 * the branches that say `as kind` in their own SQL: `pg_get_viewdef` prints
 * the labels of the first branch only, so the ones dumped before 0390 are
 * unlabelled and unreadable here. Every branch written from now on carries
 * its label, which is the whole of what this is for - and a kind that is in
 * the list but no longer in any view is not an error, because a branch can
 * be removed from a later migration without rewriting the older one.
 */
import { readFileSync, readdirSync } from "node:fs";

const problems = [];
const bad = (line) => problems.push(line);
const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");

const tab = read("app/(app)/clients/[id]/activity-tab.tsx");
const listed = [...(tab.match(/export const ACTIVITY_KINDS = \[([\s\S]*?)\]/)?.[1] ?? "").matchAll(/"([^"]+)"/g)]
  .map((m) => m[1]);

if (listed.length === 0) {
  bad("ACTIVITY_KINDS is empty or has moved, so the Activity tab has no filter to build");
}

/** Which migration said it, so the message can name the file to look in. */
const saidBy = new Map();
const dir = new URL("supabase/migrations/", root);
for (const name of readdirSync(dir).filter((n) => n.endsWith(".sql"))) {
  const sql = readFileSync(new URL(name, dir), "utf8");
  if (!/client_activity/.test(sql)) continue;
  for (const m of sql.matchAll(/'([A-Z][A-Za-z -]*)'::text\s+as\s+kind/gi)) {
    if (!saidBy.has(m[1])) saidBy.set(m[1], name);
  }
}

if (saidBy.size === 0) {
  bad("no migration labels an activity branch with `as kind`, so this check is asking nothing");
}

for (const [kind, where] of saidBy) {
  if (!listed.includes(kind)) {
    bad(
      `${where} emits activity of kind "${kind}" and ACTIVITY_KINDS does not list it, ` +
        "so those rows have no chip and cannot be filtered to",
    );
  }
}

/**
 * And the one this was written for.
 *
 * A client's answer about a place is the only row in the stream that is not
 * ours, so it is the one most worth being able to pick out.
 */
if (!listed.includes("Rating")) {
  bad("ACTIVITY_KINDS has no \"Rating\", so what a client said about a place cannot be filtered to");
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the activity kinds`);
  process.exit(1);
}
console.log(
  `  ok  ${saidBy.size} labelled activity kind(s) all have a chip, of the ${listed.length} the tab offers`,
);
