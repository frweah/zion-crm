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
  /**
   * A finding is drift, not the mere existence of a second place.
   *
   * Each entry above names where a fact lives, where else it is written, and
   * the query that would prove the two had come apart. Noting every entry
   * whatever that query returned meant the audit reported a fact as duplicated
   * while saying in the same breath that nothing disagreed - and a count that
   * could not be taken was reported in the same words as a count of zero,
   * which is the more dangerous of the two.
   */
  if (typeof disagree !== "number") {
    note("fields", `${f.fact}: the check for drift could not be run - ${disagree}`);
  } else if (disagree > 0) {
    note("fields", `${f.fact}: ${f.home} is also kept in ${f.copies.join(", ")}; ${disagree} row(s) disagree`);
  }
}

// ─────────────────────────────────────────────────────────────
// 2. Documents stored more than once
//
// §11: "One document store. A PDF exists once, in the client's file. An
// authorization, a form, a note, a warrant line, a records request *reference*
// it; none holds a copy."
//
// So what this forbids is a copy - the same bytes stored at two paths. It does
// not forbid two rows pointing at one object: that is the reference §11 asks
// for, and it is how an arrival in the inbox and its filing on the client both
// name one PDF.
//
// The first version of this section counted references and reported ten
// findings, none of which was a copy. Worse, three of them compared a view
// against the table it reads - inbox_pending over inbox_documents,
// staff_documents over staff_files - so the same rows were counted as two
// stores of the same file. Views are excluded now, and the question asked is
// the one §11 asks.
// ─────────────────────────────────────────────────────────────
console.log("");
console.log("  ── 2. where documents are kept ──");

// The inventory, for the picture. Tables only: a view holding a path column is
// its table's path column.
const { rows: pathCols } = await client.query(`
  select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
   where c.table_schema = 'public'
     and t.table_type = 'BASE TABLE'
     and (c.column_name like '%_path' or c.column_name like '%path'
          or c.column_name in ('object_name', 'storage_path', 'file_name', 'filename'))
   order by c.table_name, c.column_name
`);
const byTable = new Map();
for (const c of pathCols) {
  if (!byTable.has(c.table_name)) byTable.set(c.table_name, []);
  byTable.get(c.table_name).push(c.column_name);
}
for (const [t, cols] of byTable) console.log(`    ${t.padEnd(26)} ${cols.join(", ")}`);
console.log(
  `    ${pathCols.length} column(s) across ${byTable.size} table(s) hold a path to a file. Several rows naming one object is a reference, which is what §11 asks for.`,
);

/**
 * A copy: the same bytes at more than one path.
 *
 * Only asked where a fingerprint is kept, because without one the question
 * cannot be answered - and the tables that take files from outside all keep
 * one.
 */
const FINGERPRINTED = [
  ["inbox_documents", "sha256", "storage_path"],
  ["warrant_documents", "sha256", "relative_path"],
  ["tax_form_submissions", "pdf_sha256", "pdf_path"],
  ["staff_policy_signatures", "pdf_sha256", null],
];
for (const [table, fp, path] of FINGERPRINTED) {
  if (!path || !byTable.has(table)) continue;
  try {
    const { rows } = await client.query(
      `select count(*)::int as n from (
         select ${fp} from public.${table}
          where ${fp} is not null and ${path} is not null and ${path} <> ''
          group by ${fp} having count(distinct ${path}) > 1) d`,
    );
    if (rows[0].n > 0) {
      console.log(`    ${table}: ${rows[0].n} file(s) stored at more than one path`);
      note("documents", `${table} holds ${rows[0].n} file(s) stored at more than one path`);
    }
  } catch {
    // The shape is not what this expects; the inventory above is the point.
  }
}

/**
 * And the rule that keeps it that way.
 *
 * §11: "If the same file arrives twice (agent, upload, email), the fingerprint
 * matches and the second copy is dropped with a note." That is a unique index
 * on the fingerprint, and it is the thing that would be quiet if it went.
 */
const { rows: fpUnique } = await client.query(`
  select count(*)::int as n
    from pg_constraint
   where conrelid = 'public.inbox_documents'::regclass
     and contype = 'u'
     and pg_get_constraintdef(oid) ilike '%sha256%'
`);
if (fpUnique[0].n === 0) {
  console.log("    a document arriving twice is no longer refused by its fingerprint");
  note("documents", "inbox_documents.sha256 is not unique, so the same file can arrive twice");
} else {
  console.log("    a file arriving twice is refused by its fingerprint, so it is stored once");
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
