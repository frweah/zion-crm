/**
 * Runs .sql files against the Supabase Postgres database, in the order given.
 *
 *   node --env-file=.env.local scripts/run-sql.mjs supabase/migrations/*.sql
 *
 * Credentials come from .env.local (git-ignored) — never from arguments, so
 * they stay out of shell history. NOTICE output is printed, which is how the
 * verification script reports what it checked.
 */
import { readFile } from "node:fs/promises";
import { basename } from "node:path";
import pg from "pg";

const files = process.argv.slice(2);
if (files.length === 0) {
  console.error("Usage: node --env-file=.env.local scripts/run-sql.mjs <file.sql> ...");
  process.exit(1);
}

const config = {
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
  statement_timeout: 120000,
};

if (!config.host || !config.password) {
  console.error("SUPABASE_DB_HOST and SUPABASE_DB_PASSWORD must be set in .env.local");
  process.exit(1);
}

const client = new pg.Client(config);
client.on("notice", (n) => console.log("   " + (n.message ?? "").trim()));

try {
  await client.connect();
  console.log(`connected to ${config.host}:${config.port}\n`);
} catch (err) {
  console.error(`could not connect to ${config.host}:${config.port} — ${err.message}`);
  process.exit(2);
}

let failed = false;

for (const file of files) {
  const label = basename(file);
  process.stdout.write(`${label} ... `);
  try {
    const sql = await readFile(file, "utf8");
    console.log("");
    await client.query(sql);
    console.log(`   OK  ${label}\n`);
  } catch (err) {
    failed = true;
    console.error(`   FAILED  ${label}`);
    console.error(`   ${err.message}`);
    if (err.position) console.error(`   at character ${err.position}`);
    if (err.hint) console.error(`   hint: ${err.hint}`);
    break;
  }
}

await client.end();
process.exit(failed ? 1 : 0);
