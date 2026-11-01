/**
 * Runs an enable_*.sql with the address and the secret filled in.
 *
 *   node --env-file=.env.local scripts/enable-schedule.mjs supabase/enable_monday_health.sql
 *
 * The enable scripts ship with `YOUR-APP-URL` and `YOUR-CRON-SECRET` in them,
 * which is right: neither belongs in the repository. Filling them in by hand
 * means a file on somebody's disk with the secret in it, and the one rule
 * about that secret is that it is never written anywhere but Vercel and
 * `cron.job`.
 *
 * So the substitution happens in memory, between reading the file and sending
 * the statement. Nothing is written and nothing is printed - the output says
 * which job was scheduled and on what cron line, and never the command it was
 * scheduled with, because that command contains the secret.
 */
import { readFile } from "node:fs/promises";
import pg from "pg";

const file = process.argv[2];
if (!file) {
  console.error("Usage: node --env-file=.env.local scripts/enable-schedule.mjs <supabase/enable_*.sql>");
  process.exit(1);
}

const site = process.env.NEXT_PUBLIC_SITE_URL;
const secret = process.env.CRON_SECRET;
if (!site || !secret) {
  console.error("NEXT_PUBLIC_SITE_URL and CRON_SECRET must both be set in .env.local");
  process.exit(2);
}

const sql = (await readFile(file, "utf8"))
  .split("YOUR-APP-URL")
  .join(site.replace(/\/$/, ""))
  .split("YOUR-CRON-SECRET")
  .join(secret);

if (sql.includes("YOUR-APP-URL") || sql.includes("YOUR-CRON-SECRET")) {
  console.error("a placeholder survived the substitution; nothing was run");
  process.exit(2);
}

const client = new pg.Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
});

await client.connect();
try {
  await client.query(sql);
  // The job's name and cron line, never its command.
  const { rows } = await client.query(
    "select jobname, schedule, active from cron.job where jobname like 'zion-%' order by jobname",
  );
  console.log(`ran ${file}\n`);
  for (const r of rows) {
    console.log(`  ${r.jobname.padEnd(24)} ${r.schedule.padEnd(16)} active=${r.active}`);
  }
} finally {
  await client.end();
}
