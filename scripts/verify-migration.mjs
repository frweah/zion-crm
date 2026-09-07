/**
 * Reconciles the migrated data against the source dataset.
 *
 *   node --env-file=.env.local scripts/verify-migration.mjs ../zion-crm-prototype.jsx
 *
 * Counts alone would not catch a column mapped to the wrong field, so this
 * also checks money and hours totals, the stage distribution, the flags the
 * import was told to preserve, and one record field by field.
 *
 * Scoped to rows the migration created — every migrated table carries the
 * original id in legacy_id. Comparing whole-table totals worked exactly once:
 * the day staff started writing notes, this began reporting corruption that
 * was really just people doing their jobs. A check that cries wolf as the
 * system gets used is a check nobody will run.
 *
 * What it still catches is what matters: migrated rows being lost, altered, or
 * mapped to the wrong field.
 *
 * Exits non-zero on any mismatch.
 */
import { readFile } from "node:fs/promises";
import pg from "pg";

const source = process.argv[2] ?? "../zion-crm-prototype.jsx";
const src = await readFile(source, "utf8");
const DATA = JSON.parse(src.match(/const DATA = (\{.*?\});\r?\n/s)[1]);

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: "postgres",
  ssl: { rejectUnauthorized: false },
});
await client.connect();

const failures = [];
const one = async (sql, params) => (await client.query(sql, params)).rows[0];

function check(label, expected, actual) {
  const ok = String(expected) === String(actual);
  console.log(`  ${ok ? "ok " : "FAIL"}  ${label.padEnd(38)} source=${expected}  db=${actual}`);
  if (!ok) failures.push(label);
}

const migrated = (table) => one(`select count(*) n from ${table} where legacy_id is not null`);

check("clients", DATA.clients.length, (await migrated("clients")).n);
check("counselors", DATA.counselors.length, (await migrated("counselors")).n);
check("authorizations", DATA.authorizations.length, (await migrated("authorizations")).n);
check("invoices", DATA.invoices.length, (await migrated("invoices")).n);
check("placements", DATA.placements.length, (await migrated("placements")).n);
check("notes", DATA.notes.length, (await migrated("notes")).n);

const paid = DATA.invoices.filter((i) => i.status === "Paid").reduce((t, i) => t + i.amount, 0);
check(
  "total paid invoiced",
  paid.toFixed(2),
  Number((await one("select coalesce(sum(amount),0) n from invoices where status='Paid'")).n).toFixed(2),
);

const hours = DATA.authorizations.filter((a) => a.totalHours).reduce((t, a) => t + a.totalHours, 0);
check(
  "total authorized hours",
  hours.toFixed(2),
  Number((await one("select coalesce(sum(total_hours),0) n from authorizations")).n).toFixed(2),
);

check(
  "clients flagged for review",
  DATA.clients.filter((c) => c.importReview).length,
  (await one("select count(*) n from clients where import_review <> ''")).n,
);
check(
  "ghl ids preserved",
  DATA.clients.filter((c) => c.ghlId).length,
  (await one("select count(*) n from clients where ghl_id is not null")).n,
);
check(
  "clients closed",
  DATA.clients.filter((c) => c.status === "Closed").length,
  (await one("select count(*) n from clients where status='Closed'")).n,
);
// client_private has no legacy_id, so this compares values rather than a
// count: every address the workbook carried must still be exactly what it was.
// Addresses added since are none of this check's business.
{
  const withAddress = DATA.clients.filter((c) => c.address);
  const { rows } = await client.query(
    `select c.legacy_id, cp.address
       from public.client_private cp
       join public.clients c on c.id = cp.client_id
      where c.legacy_id is not null`,
  );
  const byLegacy = new Map(rows.map((r) => [r.legacy_id, r.address]));
  const wrong = withAddress.filter((c) => byLegacy.get(c.id) !== c.address);
  check(
    "addresses (restricted tier)",
    `${withAddress.length} intact`,
    `${withAddress.length - wrong.length} intact`,
  );
  if (wrong.length) {
    for (const c of wrong.slice(0, 3)) {
      console.log(`        ${c.id}: expected "${c.address}", found "${byLegacy.get(c.id) ?? "(missing)"}"`);
    }
  }
}

const srcStages = {};
for (const c of DATA.clients) srcStages[c.stage] = (srcStages[c.stage] ?? 0) + 1;
const dbStages = Object.fromEntries(
  (await client.query("select stage, count(*) n from clients group by stage")).rows.map((r) => [
    r.stage,
    Number(r.n),
  ]),
);
for (const stage of Object.keys(srcStages).sort()) {
  check(`stage: ${stage}`, srcStages[stage], dbStages[stage] ?? 0);
}

// One record checked field by field — counts would not notice a swapped column.
const sample = DATA.clients.find((c) => c.id === "c1002");
if (sample) {
  const row = await one(
    "select name, phone, email, stage, counselor_id, import_review from clients where legacy_id='c1002'",
  );
  const counselor = row?.counselor_id
    ? (await one("select name from counselors where id=$1", [row.counselor_id]))?.name
    : "";
  check("c1002 name", sample.name, row?.name);
  check("c1002 phone", sample.phone, row?.phone);
  check("c1002 email", sample.email, row?.email);
  check("c1002 counselor", sample.counselor, counselor);
  check("c1002 stage", sample.stage, row?.stage);
  check("c1002 review flag", sample.importReview, row?.import_review);
}

await client.end();

console.log(
  failures.length
    ? `\n${failures.length} MISMATCH(ES): ${failures.join(", ")}`
    : "\n--- MIGRATION RECONCILED ---",
);
process.exit(failures.length ? 1 : 0);
