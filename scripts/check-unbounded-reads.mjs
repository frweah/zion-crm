/**
 * No screen asks a growing table for all of it.
 *
 *   node scripts/check-unbounded-reads.mjs   (also runs before every build)
 *
 * The stress test on 16 Oct 2026 found two of these and they had the same
 * shape. Billing → Hours asked service_entries for every row ever logged, with
 * no filter and no limit. The Clients list asked for every client, every job
 * match and every row of the activity view, then sorted and searched them in
 * memory. Both were free at the time and neither would have stayed free: the
 * tables they read are the ones that grow with the practice's work, and the
 * screens only ever show a page.
 *
 * What makes them hard to notice is that nothing breaks. The page is correct
 * and fast on a small database and gets slower by a few milliseconds a week,
 * so there is never a day when somebody says it is broken.
 *
 * So: a read of one of the tables below has to be bounded by something — a
 * row limit, a page, a filter, or asking for one row. A count (head: true)
 * is bounded by definition. Anything else fails here, where it is cheap,
 * rather than in a year on somebody's Monday morning.
 *
 * Adding a table to this list is how you say "this one grows". Taking a read
 * out of scope is a filter, a .limit() or a .range() — not an exception.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

/**
 * Tables that grow with the work, not with the caseload.
 *
 * The distinction is the whole point. A practice with 500 clients has 500
 * rows in `clients` and a lookup map of names costs nothing — so reading all
 * of `clients` to label a dropdown is not what this check is about. But those
 * same 500 clients log hours every week for years, and `service_entries` has
 * no ceiling at all. A table whose size is set by how long the practice has
 * been running is one nobody should ask for whole.
 *
 * client_last_activity is a view, and the most expensive thing on this list:
 * twelve unions over most of these tables, grouped per client.
 */
const GROWING = [
  "service_entries",
  "attachments",
  "lead_matches",
  "messages",
  "notes",
  "contact_log",
  "calendar_events",
  "mail_log",
  "sms_messages",
  "payments",
  "journal_lines",
  "client_activity",
  "client_last_activity",
];

/**
 * Anything that makes a read bounded: a page of rows, a row limit, a filter
 * that names what is wanted, one row, or a count.
 *
 * .or() counts because every one in this codebase narrows to a person or a
 * date range; .select("*", { head: true }) is a count and reads no rows.
 */
const BOUNDED = [
  ".limit(",
  ".range(",
  ".maybeSingle(",
  ".single(",
  ".eq(",
  ".neq(",
  ".in(",
  ".gt(",
  ".gte(",
  ".lt(",
  ".lte(",
  ".like(",
  ".ilike(",
  ".is(",
  ".or(",
  ".match(",
  ".filter(",
  ".contains(",
  ".overlaps(",
  ".textSearch(",
  "head: true",
];

/**
 * The method chain that follows a .from(), and nothing after it.
 *
 * Counted by brackets rather than matched by a pattern. The first version of
 * this read to the next line starting with `supabase.`, which meant a query
 * written as `supabase\n  .from(...)` never ended — so the *next* query's
 * .eq() was read as this one's filter and client_last_activity, the most
 * expensive unbounded read in the codebase, came back clean. A check that
 * asks a question near the rule passes the bug it was written for, which is
 * the whole reason this file exists.
 *
 * So: walk forward, and stop at the comma, semicolon or closing bracket that
 * ends this expression at the depth it started.
 */
function chainAfter(source, start) {
  let depth = 0;
  for (let i = start; i < source.length; i++) {
    const ch = source[i];
    if (ch === "(" || ch === "[" || ch === "{") depth++;
    else if (ch === ")" || ch === "]" || ch === "}") {
      if (depth === 0) return source.slice(start, i);
      depth--;
    } else if ((ch === "," || ch === ";") && depth === 0) {
      return source.slice(start, i);
    }
  }
  return source.slice(start);
}

function walk(dir) {
  for (const entry of readdirSync(dir)) {
    const full = path.join(dir, entry);
    if (statSync(full).isDirectory()) {
      if (entry === "node_modules" || entry === ".next" || entry === ".probe") continue;
      walk(full);
      continue;
    }
    if (!/\.tsx?$/.test(entry)) continue;

    const rel = path.relative(root, full).split(path.sep).join("/");
    if (rel.endsWith("database.types.ts")) continue;

    const source = readFileSync(full, "utf8");
    if (!source.includes(".from(")) continue;

    // Each .from("table") and the chain that follows it, to the end of the
    // statement. A chain ends at the semicolon or comma that closes the call;
    // taking 400 characters is more than any chain here and costs nothing.
    for (const m of source.matchAll(/\.from\(\s*["'`]([a-z_]+)["'`]\s*\)/g)) {
      const table = m[1];
      if (!GROWING.includes(table)) continue;

      const scope = chainAfter(source, m.index + m[0].length);

      // A write is not a read. An insert names its own rows, and an update or
      // a delete is bounded by the policy that lets it through.
      if (/^\s*\.(insert|update|upsert|delete)\(/.test(scope)) continue;

      if (BOUNDED.some((b) => scope.includes(b))) continue;

      const line = source.slice(0, m.index).split("\n").length;
      failures.push(
        `${rel}:${line} reads every row of ${table} — no filter, no limit and no page. ` +
          `It grows with the practice, and the screen shows a page of it.`,
      );
    }
  }
}

walk(path.join(root, "app"));
walk(path.join(root, "lib"));

if (failures.length > 0) {
  console.error("");
  for (const f of failures) console.error(`  FAILED  ${f}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log(`  ok  every read of the ${GROWING.length} growing tables is bounded by a filter, a page or a limit`);
console.log("");
console.log("--- READS VERIFIED ---");
