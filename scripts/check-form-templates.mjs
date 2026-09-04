/**
 * Checks that lib/form-templates.ts and the form_templates table agree.
 *
 *   node --env-file=.env.local scripts/check-form-templates.mjs
 *
 * The templates exist in two places on purpose: the field definitions belong
 * in code, but the database needs to know which service types require which
 * form so it can refuse to let an invoice be sent. That duplication is only
 * safe if something checks it — a template marked required in code and not in
 * the table would show staff a form they must complete while the gate quietly
 * let the invoice through.
 */
import pg from "pg";

const { FORM_TEMPLATES } = await import("../lib/form-templates.ts");

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: "postgres",
  ssl: { rejectUnauthorized: false },
});
await client.connect();

const { rows } = await client.query(
  "select id, usor, name, services, required_for_billing, monthly, incoming, sensitive from public.form_templates order by sort_order",
);
await client.end();

const byId = new Map(rows.map((r) => [r.id, r]));
const failures = [];

const same = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

for (const t of FORM_TEMPLATES) {
  const db = byId.get(t.id);
  if (!db) {
    failures.push(`${t.id} (${t.usor}) is in code but not in form_templates`);
    continue;
  }
  if (db.usor !== t.usor) failures.push(`${t.id}: usor "${db.usor}" in db vs "${t.usor}" in code`);
  if (db.name !== t.name) failures.push(`${t.id}: name differs between db and code`);
  if (!same(db.services, t.services)) {
    failures.push(
      `${t.id}: services [${db.services}] in db vs [${t.services}] in code — this decides which invoices are gated`,
    );
  }
  if (db.required_for_billing !== Boolean(t.requiredForBilling)) {
    failures.push(`${t.id}: required_for_billing ${db.required_for_billing} in db vs ${Boolean(t.requiredForBilling)} in code`);
  }
  if (db.monthly !== Boolean(t.monthly)) {
    failures.push(`${t.id}: monthly ${db.monthly} in db vs ${Boolean(t.monthly)} in code`);
  }
  if (db.incoming !== Boolean(t.incoming)) {
    failures.push(`${t.id}: incoming ${db.incoming} in db vs ${Boolean(t.incoming)} in code`);
  }
  if (db.sensitive !== Boolean(t.sensitive)) {
    failures.push(
      `${t.id}: sensitive ${db.sensitive} in db vs ${Boolean(t.sensitive)} in code — this decides who can open the form`,
    );
  }
  console.log(`  ok   ${t.usor.padEnd(14)} ${t.services.length ? t.services.join(", ") : "(incoming)"}`);
}

for (const r of rows) {
  if (!FORM_TEMPLATES.some((t) => t.id === r.id)) {
    failures.push(`${r.id} (${r.usor}) is in form_templates but not in code`);
  }
}

if (failures.length) {
  console.error(`\n${failures.length} MISMATCH(ES):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(`\n--- ${FORM_TEMPLATES.length} FORM TEMPLATES AGREE ---`);
