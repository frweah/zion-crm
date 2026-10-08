/**
 * The duplication audit (Billing Simplification Brief, §11).
 *
 *   node --env-file=.env.local scripts/duplication-audit.mjs
 *
 * The owner's rule: "No item should be repeated. One PDF attached should
 * fall in the right place and be referenced where necessary with no need to
 * duplicate it all over the CRM."
 *
 * So this asks the database and the screens three questions and prints what
 * it finds. It is a report, not a check: the build is what removes the
 * findings, and §11 says the build is not done until a later run finds none.
 * Pass --check to make it exit non-zero while anything is outstanding, which
 * is how it joins the suite once the work is done.
 *
 *   1. Which facts are stored in more than one table. Not column names that
 *      merely rhyme - the same fact, with a count of rows that disagree,
 *      because a copy nobody has contradicted yet is still a copy and the
 *      disagreement is what proves it.
 *
 *   2. Which documents are stored more than once: the columns that hold a
 *      storage path or a file name, and any path that appears twice.
 *
 *   3. Which screens list the same records as another screen.
 */
import { readdir, readFile } from "node:fs/promises";
import pg from "pg";

const CHECK = process.argv.includes("--check");

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  statement_timeout: 120000,
});

const findings = [];
const note = (section, text) => findings.push({ section, text });

await client.connect();

// ─────────────────────────────────────────────────────────────
// 1. The same fact in two tables
//
// Each entry is a fact, where it is meant to live, and where else it is
// kept - with the query that counts the rows where the two disagree.
// ─────────────────────────────────────────────────────────────
const FACTS = [
  // Five of the facts this audit was built to watch were duplicated between
  // the authorization, the billing item and the invoice. §§1 and 10 removed
  // both of the copies, so those facts now live in one place by construction
  // rather than by agreement - there is nothing left to disagree with. The
  // check that keeps it that way is verify_one_door, which refuses a second
  // record rather than counting how far two have drifted apart.
  //
  // What stays here is what is still kept twice.
  // "How to reach the counselor" was here. clients.counselor_contact was a
  // free-text box holding the counselor's phone, written a second time and
  // disagreeing with the counselor's own record on twelve clients - every one of
  // them the same number in a different format, bar one phone and one fax that
  // were only written there. Those two were moved onto the counselor and the box
  // was dropped (0175), so there is nothing left to disagree.
  //
  // referring_office is deliberately not on this list: it is who sent the
  // client, which can be a different office from the counselor's and often is.
  {
    // Two different things that look like one: what somebody worked, and what
    // the practice bills. They are allowed to differ, and the audit watches
    // the pair that must not - the same hours entered against the same
    // authorization twice.
    fact: "Hours worked",
    home: "work_sessions (what somebody did) and service_entries (what is billed)",
    copies: ["service_entries, where the same day is entered twice for one authorization"],
    disagree: `select count(*) from (
                 select e.auth_id, e.date, e.hours, count(*)
                   from public.service_entries e
                  where not e.non_billable
                  group by 1, 2, 3 having count(*) > 1) d`,
  },
];

console.log("");
console.log("  ── 1. the same fact, kept in more than one place ──");
for (const f of FACTS) {
  let disagree = null;
  try {
    disagree = Number((await client.query(f.disagree)).rows[0].count);
  } catch (e) {
    disagree = `could not be counted (${e.message.split("\n")[0]})`;
  }
  console.log("");
  console.log(`  ${f.fact}`);
  console.log(`    lives in   ${f.home}`);
  console.log(`    also in    ${f.copies.join(" | ")}`);
  console.log(`    disagree   ${disagree}`);
  note("fields", `${f.fact}: ${f.home} is also kept in ${f.copies.join(", ")}; ${disagree} row(s) disagree`);
}

// ─────────────────────────────────────────────────────────────
// 2. Documents stored more than once
// ─────────────────────────────────────────────────────────────
console.log("");
console.log("  ── 2. where documents are kept ──");
const { rows: pathCols } = await client.query(`
  select table_name, column_name
    from information_schema.columns
   where table_schema = 'public'
     and (column_name like '%_path' or column_name like '%path'
          or column_name in ('object_name', 'storage_path', 'file_name', 'filename'))
   order by table_name, column_name
`);
const byTable = new Map();
for (const c of pathCols) {
  if (!byTable.has(c.table_name)) byTable.set(c.table_name, []);
  byTable.get(c.table_name).push(c.column_name);
}
for (const [t, cols] of byTable) console.log(`    ${t.padEnd(26)} ${cols.join(", ")}`);
console.log(`    ${pathCols.length} column(s) across ${byTable.size} table(s) hold a path to a file.`);
note(
  "documents",
  `${pathCols.length} columns across ${byTable.size} tables hold a file path: ${[...byTable.keys()].join(", ")}. A PDF referenced from two of them is stored twice.`,
);

// The same stored object named by two different rows.
//
// A path, not a filename. Two clients can both have an "authorization.pdf" and
// that is not a duplicate of anything; two rows pointing at the same object in
// storage is. The filename columns are listed above for the picture, and
// excluded here for that reason.
const PATHLIKE = /(storage_path|relative_path|image_path|attachment_path|document_path|photo_path|pdf_path)$/;
for (const [t, cols] of byTable) {
  for (const col of cols.filter((c) => PATHLIKE.test(c))) {
    try {
      const { rows } = await client.query(
        `select count(*)::int as n from (
           select ${col} from public.${t} where ${col} is not null and ${col} <> ''
           group by ${col} having count(*) > 1) d`,
      );
      if (rows[0].n > 0) {
        console.log(`    ${t}.${col}: ${rows[0].n} object(s) pointed at by more than one row`);
        note("documents", `${t}.${col} has ${rows[0].n} stored object(s) referenced by more than one row`);
      }
    } catch {
      // Not a table we can read this way; the column list above is the point.
    }
  }
}

// And the same object held in two different tables, which is the one §11
// actually forbids: a PDF exists once, in the client's file, and everything
// else references it.
const STORES = [...byTable.entries()].flatMap(([t, cols]) =>
  cols.filter((c) => PATHLIKE.test(c)).map((c) => [t, c]),
);
for (let i = 0; i < STORES.length; i++) {
  for (let j = i + 1; j < STORES.length; j++) {
    const [t1, c1] = STORES[i];
    const [t2, c2] = STORES[j];
    try {
      const { rows } = await client.query(
        `select count(*)::int as n
           from public.${t1} a join public.${t2} b on a.${c1} = b.${c2}
          where a.${c1} is not null and a.${c1} <> ''`,
      );
      if (rows[0].n > 0) {
        console.log(`    ${t1}.${c1} and ${t2}.${c2} point at ${rows[0].n} of the same object(s)`);
        note("documents", `${t1}.${c1} and ${t2}.${c2} both point at ${rows[0].n} stored object(s)`);
      }
    } catch {
      // Different shapes of path; nothing to compare.
    }
  }
}

// ─────────────────────────────────────────────────────────────
// 3. Screens that list the same records
// ─────────────────────────────────────────────────────────────
console.log("");
console.log("  ── 3. screens listing the same records ──");
const APP = new URL("../app/(app)/", import.meta.url);
async function files(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const url = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
    if (e.isDirectory()) out.push(...(await files(url)));
    else if (e.name.endsWith(".tsx") || e.name.endsWith(".ts")) out.push(url);
  }
  return out;
}
const rel = (url) => decodeURIComponent(url.pathname).split("/app/(app)/")[1] ?? url.pathname;

// A screen reading a record is not duplication - it is the point of keeping the
// fact in one place, and eleven screens reading one authorization is §11
// working, not failing. Counting readers measures the opposite of the rule.
//
// What §11 forbids is "if two screens show the same records, one of them goes",
// and whether a given file *shows* records or merely totals them is not
// something a regular expression can tell: `.map(` is in both. An earlier
// version of this check guessed, and reported eleven screens as findings when
// none of them was a rival list. A check that cries wolf is worse than no
// check, because it teaches people to skip the output.
//
// So this section reports and does not judge. What keeps the rule is a thing
// the code can state exactly: the working list is one component - Worklist, in
// billing/worklist.tsx - and both the Billing page and the client's Billing tab
// render that one (§12.6). If somebody writes a second one, it shows up here as
// a file that queries the worklist and lays out its own table, and the reviewer
// decides.
const APPFILES = await files(APP);
// Plain string matching: a regex here needs its brackets escaped through two
// layers and silently matches nothing when one of them is lost.
const shows = (src, t) => src.includes(`from("${t}")`) || src.includes(`rpc("${t}")`);
const WATCH = ["authorizations", "payments", "service_entries", "warrant_lines", "billed_work"];
const counts = new Map(WATCH.map((t) => [t, []]));
let shared = 0;
const ownTable = [];
for (const url of APPFILES) {
  const src = await readFile(url, "utf8");
  const name = rel(url);
  if (/export function Worklist\b/.test(src)) shared += 1;
  if (/rpc\("billing_worklist"\)/.test(src) && !/<Worklist\b/.test(src) && /<DataTable/.test(src)) {
    ownTable.push(name);
  }
  for (const t of WATCH) if (shows(src, t)) counts.get(t).push(name);
}
console.log(`    the working list is one component, found ${shared} time(s) (expected 1)`);
if (shared !== 1) note("lists", `the shared working list component was found ${shared} times, not once`);
if (ownTable.length) {
  for (const n of ownTable) console.log(`    ${n} queries the working list and lays out its own table`);
  note("lists", `these query the working list instead of using the shared one: ${ownTable.join(", ")}`);
} else {
  console.log("    and no screen lays out a second one");
}
console.log("");
console.log("    read by, for information - not findings:");
for (const [t, where] of counts) console.log(`      ${t.padEnd(18)} ${where.length} screen(s)`);

await client.end();

console.log("");
console.log(`  ${findings.length} finding(s).`);
console.log("");
if (CHECK && findings.length > 0) {
  console.error("  FAILED  the duplication audit still finds repeated facts, documents or lists");
  process.exit(1);
}
console.log("--- DUPLICATION AUDIT RUN ---");
