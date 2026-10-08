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
  {
    fact: "Which service a piece of work is for",
    home: "authorizations.service_type",
    copies: ["billing_items.service", "invoices.service_type"],
    disagree: `select count(*) from public.billing_items i
                 join public.authorizations a on a.id = i.auth_id
                where i.service is distinct from a.service_type`,
  },
  {
    fact: "The rate and whether it is hourly",
    home: "authorizations.rate, authorizations.rate_type",
    copies: ["billing_items.rate, billing_items.billing_type", "rate_schedule"],
    disagree: `select count(*) from public.billing_items i
                 join public.authorizations a on a.id = i.auth_id
                where i.rate is not null and i.rate is distinct from a.rate`,
  },
  {
    fact: "What the work came to",
    home: "authorizations (rate x hours)",
    copies: ["billing_items.amount", "invoices.amount"],
    disagree: `select count(*) from public.invoices v
                 join public.billing_items i on i.invoice_id = v.id
                where v.amount is distinct from i.amount`,
  },
  {
    fact: "When it was sent and to whom",
    home: "billing_items.submitted_at, billing_items.recipient",
    copies: ["invoices.sent_date, invoices.payee"],
    disagree: `select count(*) from public.invoices v
                 join public.billing_items i on i.invoice_id = v.id
                where v.sent_date is distinct from i.submitted_at::date`,
  },
  {
    fact: "That it was paid, and on what warrant",
    home: "billing_items.paid_on, billing_items.warrant",
    copies: ["invoices.paid_date, invoices.warrant", "payments.warrant_no", "warrant_lines.amount"],
    disagree: `select count(*) from public.invoices v
                 join public.billing_items i on i.invoice_id = v.id
                where v.paid_date is distinct from i.paid_on`,
  },
  {
    fact: "Who the counselor and billing office are",
    home: "clients.counselor_id, counselors.office",
    copies: ["clients.counselor_contact", "clients.referring_office", "billing_offices"],
    disagree: `select count(*) from public.clients c
                 join public.counselors k on k.id = c.counselor_id
                where nullif(c.referring_office, '') is not null
                  and nullif(k.office, '') is not null
                  and c.referring_office is distinct from k.office`,
  },
  {
    fact: "Hours worked",
    home: "work_sessions (what somebody did) and service_entries (what is billed)",
    copies: ["billing_items.hours"],
    disagree: `select count(*) from public.billing_items i
                where i.hours is not null
                  and i.auth_id is not null
                  and i.hours is distinct from (
                    select coalesce(sum(e.hours), 0) from public.service_entries e
                     where e.auth_id = i.auth_id and not e.non_billable
                       and (i.period is null or date_trunc('month', e.date) = i.period))`,
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
for (const [t, cols] of byTable) {
  for (const col of cols) {
    try {
      const { rows } = await client.query(
        `select count(*)::int as n from (
           select ${col} from public.${t} where ${col} is not null and ${col} <> ''
           group by ${col} having count(*) > 1) d`,
      );
      if (rows[0].n > 0) {
        console.log(`    ${t}.${col}: ${rows[0].n} path(s) used by more than one row`);
        note("documents", `${t}.${col} has ${rows[0].n} path(s) referenced by more than one row`);
      }
    } catch {
      // Not a table we can read this way; the column list above is the point.
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

const WATCH = ["authorizations", "billing_items", "invoices", "payments", "service_entries", "warrant_lines"];
const readers = new Map(WATCH.map((t) => [t, []]));
for (const url of await files(APP)) {
  const src = await readFile(url, "utf8");
  for (const t of WATCH) {
    if (new RegExp(`from\\("${t}"\\)|from\\('${t}'\\)`).test(src)) readers.get(t).push(rel(url));
  }
}
for (const [t, where] of readers) {
  if (where.length <= 1) continue;
  console.log(`    ${t}: read by ${where.length} screens`);
  for (const w of where) console.log(`      ${w}`);
  note("lists", `${t} is listed by ${where.length} screens: ${where.join(", ")}`);
}

await client.end();

console.log("");
console.log(`  ${findings.length} finding(s).`);
console.log("");
if (CHECK && findings.length > 0) {
  console.error("  FAILED  the duplication audit still finds repeated facts, documents or lists");
  process.exit(1);
}
console.log("--- DUPLICATION AUDIT RUN ---");
