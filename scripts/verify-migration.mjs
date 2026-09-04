/**
 * Reconciles the loaded data against the source dataset.
 *
 *   node --env-file=.env.local scripts/verify-migration.mjs ../zion-crm-prototype.jsx
 *
 * Counts alone would not catch a column mapped to the wrong field, so this
 * also checks money and hours totals, the stage distribution, the flags the
 * import was told to preserve, and one record field by field.
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

check("clients", DATA.clients.length, (await one("select count(*) n from clients")).n);
check("counselors", DATA.counselors.length, (await one("select count(*) n from counselors")).n);
check("authorizations", DATA.authorizations.length, (await one("select count(*) n from authorizations")).n);
check("invoices", DATA.invoices.length, (await one("select count(*) n from invoices")).n);
check("placements", DATA.placements.length, (await one("select count(*) n from placements")).n);
check("notes", DATA.notes.length, (await one("select count(*) n from notes")).n);

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
check(
  "addresses (restricted tier)",
  DATA.clients.filter((c) => c.address).length,
  (await one("select count(*) n from client_private where address <> ''")).n,
);

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
