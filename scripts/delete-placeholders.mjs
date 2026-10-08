/**
 * Delete the placeholder authorizations nothing hangs off (§9).
 *
 *   node --env-file=.env.local scripts/delete-placeholders.mjs            # counts only
 *   node --env-file=.env.local scripts/delete-placeholders.mjs --delete   # does it
 *
 * Owner approved the nineteen on 7 Oct 2026, having seen the counts.
 *
 * The test is every table that points at an authorization, read from the
 * schema rather than from memory. That matters: six of the ten cascade, so
 * deleting an authorization would quietly take its corrections, completions,
 * hours requests, invoices, payments and service entries with it, and three
 * more would be orphaned by a SET NULL - an attachment or a warrant line
 * losing what it was attached to. The first count for this brief checked six
 * of the ten; a deletion that checked six would have been a deletion made on
 * an incomplete test.
 *
 * Nothing is deleted unless, inside one transaction:
 *   - every row still passes the full test at the moment of deletion;
 *   - every child table has exactly as many rows afterwards as before;
 *   - the sum of every payment in the database is unchanged.
 * Any of those failing rolls the whole thing back.
 */
import pg from "pg";

const DO_IT = process.argv.includes("--delete");

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

// Read from the schema, so a table added later is included without anybody
// remembering to add it here.
const { rows: refs } = await client.query(`
  select tc.table_name, kcu.column_name
    from information_schema.table_constraints tc
    join information_schema.key_column_usage kcu on kcu.constraint_name = tc.constraint_name
    join information_schema.constraint_column_usage ccu on ccu.constraint_name = tc.constraint_name
   where tc.constraint_type = 'FOREIGN KEY'
     and ccu.table_name = 'authorizations' and ccu.column_name = 'id'
   order by tc.table_name
`);

const nothingAttached = refs
  .map((r) => `not exists (select 1 from public.${r.table_name} x where x.${r.column_name} = a.id)`)
  .join("\n       and ");

const DELETABLE = `
  select a.id
    from public.authorizations a
   where a.number like '(workbook)%'
     and coalesce(a.carried_used, 0) = 0
     and ${nothingAttached}
`;

const counts = async () => {
  const out = {};
  for (const r of refs) {
    out[r.table_name] = Number((await client.query(`select count(*) from public.${r.table_name}`)).rows[0].count);
  }
  out.authorizations = Number((await client.query("select count(*) from public.authorizations")).rows[0].count);
  out.placeholders = Number(
    (await client.query("select count(*) from public.authorizations where number like '(workbook)%'")).rows[0].count,
  );
  const paid = await client.query("select coalesce(sum(amount), 0) as total from public.payments");
  out.paid = Number(paid.rows[0].total);
  return out;
};

console.log("");
console.log(`  Tested against all ${refs.length} tables that point at an authorization:`);
console.log(`    ${refs.map((r) => r.table_name).join(", ")}`);

const before = await counts();
const { rows: targets } = await client.query(DELETABLE);

console.log("");
console.log(`  ${before.placeholders} placeholder(s) in all; ${targets.length} with nothing attached by the full test.`);

if (!DO_IT) {
  console.log("");
  console.log("  Counts only. Pass --delete to remove them.");
  await client.end();
  process.exit(0);
}

try {
  await client.query("begin");
  // Re-selected inside the transaction, so a row that gained an attachment
  // between the count and the delete is no longer in the set.
  const { rows: stillClear } = await client.query(DELETABLE);
  const ids = stillClear.map((r) => r.id);
  if (ids.length !== targets.length) {
    await client.query("rollback");
    console.error("");
    console.error(`  FAILED  the set changed while deleting: ${targets.length} before, ${ids.length} now`);
    console.error("  Nothing was deleted.");
    await client.end();
    process.exit(1);
  }
  const { rowCount } = await client.query("delete from public.authorizations where id = any($1::uuid[])", [ids]);
  const after = await counts();

  const problems = [];
  if (rowCount !== targets.length) {
    problems.push(`deleted ${rowCount} where ${targets.length} were expected`);
  }
  for (const r of refs) {
    if (after[r.table_name] !== before[r.table_name]) {
      problems.push(`${r.table_name} went from ${before[r.table_name]} to ${after[r.table_name]} rows`);
    }
  }
  if (after.paid !== before.paid) {
    problems.push(`payments total went from ${before.paid} to ${after.paid}`);
  }
  if (after.authorizations !== before.authorizations - targets.length) {
    problems.push(`authorizations went from ${before.authorizations} to ${after.authorizations}`);
  }

  if (problems.length) {
    await client.query("rollback");
    console.error("");
    for (const p of problems) console.error(`  FAILED  ${p}`);
    console.error("  Nothing was deleted.");
    await client.end();
    process.exit(1);
  }

  await client.query("commit");
  console.log("");
  console.log(`  Deleted ${rowCount}.`);
  console.log(`    authorizations  ${before.authorizations} -> ${after.authorizations}`);
  console.log(`    placeholders    ${before.placeholders} -> ${after.placeholders}`);
  console.log(`    payments total  ${before.paid.toFixed(2)} -> ${after.paid.toFixed(2)} (unchanged)`);
  console.log("    every child table unchanged");
  console.log("");
  console.log("--- PLACEHOLDERS DELETED ---");
} catch (e) {
  await client.query("rollback").catch(() => {});
  console.error(`  FAILED  ${e.message.split("\n")[0]}`);
  console.error("  Nothing was deleted.");
  await client.end();
  process.exit(1);
}

await client.end();
