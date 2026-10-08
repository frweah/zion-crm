/**
 * What the placeholder cleanup would do (Billing Simplification Brief, §9).
 *
 *   node --env-file=.env.local scripts/placeholder-counts.mjs
 *
 * Counts only. Nothing is deleted here and nothing is changed: §9 says
 * report the counts before deleting, and deleting client records is the
 * owner's call, not this script's.
 *
 * A placeholder is an authorization the spreadsheet import created with no
 * USOR number - its number starts "(workbook)". §9 splits them in two:
 *
 *   deletable  no hours, no forms, no invoice, no payment. Nothing hangs off
 *              it, so removing it loses nothing.
 *   kept       holds a payment or logged hours. Deleting it would change
 *              what the practice has been paid, so it stays as history.
 *
 * Per-client numbers are printed here and deliberately not written to
 * BUILD-LOG.md: the standing rule is no client data in the repository or its
 * history, and a table of client numbers against counts is client data.
 */
import pg from "pg";

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  statement_timeout: 120000,
});
await client.connect();

const ATTACHED = `
  with p as (
    select a.id, a.client_id, a.number, a.service_type, a.status,
           coalesce(a.carried_used, 0) as carried_used,
           (select count(*) from public.service_entries e where e.auth_id = a.id) as entries,
           (select coalesce(sum(e.hours), 0) from public.service_entries e where e.auth_id = a.id) as hours,
           (select count(*) from public.forms f where f.auth_id = a.id) as forms,
           (select count(*) from public.invoices v where v.auth_id = a.id) as invoices,
           (select count(*) from public.payments y where y.auth_id = a.id) as payments,
           (select coalesce(sum(y.amount), 0) from public.payments y where y.auth_id = a.id) as paid,
           (select count(*) from public.billing_items i where i.auth_id = a.id) as items
      from public.authorizations a
     where a.number like '(workbook)%'
  )
  select *,
         (entries = 0 and forms = 0 and invoices = 0 and payments = 0
          and carried_used = 0 and items = 0) as deletable
    from p
`;

const { rows } = await client.query(ATTACHED);
const deletable = rows.filter((r) => r.deletable);
const kept = rows.filter((r) => !r.deletable);

const money = (n) => Number(n).toFixed(2);

console.log("");
console.log(`  ${rows.length} placeholder authorization(s) in all.`);
console.log(`    ${deletable.length} with nothing attached - §9 deletes these`);
console.log(`    ${kept.length} holding a payment, hours or forms - §9 keeps these as history`);
console.log("");
console.log(`  Money on the kept ones: ${money(kept.reduce((s, r) => s + Number(r.paid), 0))} paid across ${kept.filter((r) => Number(r.payments) > 0).length} placeholder(s).`);
console.log(`  Money on the deletable ones: ${money(deletable.reduce((s, r) => s + Number(r.paid), 0))} - it has to be zero, by definition.`);
console.log("");

// What is actually hanging off the ones that stay.
const why = (r) =>
  [
    Number(r.payments) > 0 ? `${r.payments} payment(s) totalling ${money(r.paid)}` : null,
    Number(r.entries) > 0 ? `${r.entries} service entr(ies), ${money(r.hours)} hours` : null,
    Number(r.carried_used) > 0 ? `${money(r.carried_used)} carried hours` : null,
    Number(r.forms) > 0 ? `${r.forms} form(s)` : null,
    Number(r.invoices) > 0 ? `${r.invoices} invoice(s)` : null,
    Number(r.items) > 0 ? `${r.items} billing item(s)` : null,
  ]
    .filter(Boolean)
    .join("; ");

console.log("  ── per client, kept ──");
const byClient = new Map();
for (const r of rows) {
  if (!byClient.has(r.client_id)) byClient.set(r.client_id, { del: 0, keep: 0, paid: 0, reasons: [] });
  const e = byClient.get(r.client_id);
  if (r.deletable) e.del += 1;
  else {
    e.keep += 1;
    e.paid += Number(r.paid);
    e.reasons.push(`${r.service_type}: ${why(r)}`);
  }
}
const { rows: names } = await client.query(
  `select id, coalesce(client_no::text, left(id::text, 8)) as who from public.clients where id = any($1::uuid[])`,
  [[...byClient.keys()]],
);
const who = new Map(names.map((n) => [n.id, n.who]));

for (const [id, e] of [...byClient.entries()].sort((a, b) => b[1].keep - a[1].keep)) {
  console.log(`    client ${who.get(id) ?? "?"}: ${e.del} to delete, ${e.keep} kept${e.paid > 0 ? `, ${money(e.paid)} paid` : ""}`);
  for (const r of e.reasons) console.log(`        ${r}`);
}

console.log("");
console.log(`  ${byClient.size} client(s) have placeholders.`);
console.log("");
console.log("--- COUNTED, NOTHING CHANGED ---");

await client.end();
