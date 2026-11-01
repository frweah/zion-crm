/**
 * The whole verification suite, in one command, and a record that it ran.
 *
 *   node --env-file=.env.local scripts/verify-all.mjs
 *
 * CLAUDE.md has always said to run the suite by hand, because every script in
 * it builds fixtures against production inside a rolled-back transaction and
 * so needs database credentials that Vercel does not have. What it did not
 * have was a record: the Monday email is meant to report the suite's result,
 * and nothing anywhere said whether it had ever been run.
 *
 * So this is the one command, and it writes to `practice_health` (0278) when
 * it finishes. "The suite passed on Thursday" is a claim this system can make;
 * "the suite passes" is not.
 *
 * Two things it does deliberately:
 *
 *   **It counts rather than pipes.** `| tail` on a run of the suite shows the
 *   last few lines and hides a failure forty files earlier, which has happened
 *   here. Every script's result is kept and the failures are printed together
 *   at the end.
 *
 *   **It records a failure as a failure.** A run that cannot reach the
 *   database records nothing at all rather than recording "not ok", because
 *   "the suite failed" and "nobody could run the suite" are different things
 *   and the Monday email should not confuse them - it reports the age of the
 *   last record, and an absent record ages visibly.
 */
import { readdir, readFile } from "node:fs/promises";
import { hostname, userInfo } from "node:os";
import pg from "pg";

const DIR = new URL("../supabase/", import.meta.url);

const config = {
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
  statement_timeout: 300000,
};

if (!config.host || !config.password) {
  console.error("SUPABASE_DB_HOST and SUPABASE_DB_PASSWORD must be set in .env.local");
  process.exit(2);
}

const names = (await readdir(DIR)).filter((n) => /^verify_.*\.sql$/.test(n)).sort();
const client = new pg.Client(config);

try {
  await client.connect();
} catch (err) {
  console.error(`could not connect to ${config.host} — ${err.message}`);
  console.error("nothing recorded: not being able to run the suite is not the suite failing");
  process.exit(2);
}

console.log(`${names.length} verification scripts against ${config.host}\n`);

const failures = [];
let passed = 0;

for (const name of names) {
  const sql = await readFile(new URL(name, DIR), "utf8");
  process.stdout.write(`  ${name} `.padEnd(52, "."));
  try {
    await client.query(sql);
    passed += 1;
    console.log(" ok");
  } catch (err) {
    failures.push({ name, message: (err.message ?? "").split("\n")[0] });
    console.log(" FAILED");
    // A failed script may have left its transaction open.
    await client.query("rollback").catch(() => {});
  }
}

console.log("");
for (const f of failures) {
  console.error(`  FAILED  ${f.name}`);
  console.error(`          ${f.message}`);
}

const ok = failures.length === 0;
const detail = ok
  ? `all ${passed} scripts passed`
  : `${failures.length} of ${names.length} failed: ${failures.map((f) => f.name).join(", ")}`;

// Recorded whichever way it went, because a failing suite is exactly what the
// Monday email exists to say out loud.
let who = "";
try {
  who = `${userInfo().username}@${hostname()}`;
} catch {
  who = "a laptop";
}

await client.query(
  `insert into public.practice_health (kind, at, ok, detail, recorded_by)
   values ('verify', now(), $1, $2, $3)
   on conflict (kind) do update
     set at = excluded.at, ok = excluded.ok,
         detail = excluded.detail, recorded_by = excluded.recorded_by`,
  [ok, detail.slice(0, 500), who.slice(0, 120)],
);
await client.end();

console.log(`${passed} of ${names.length} passed — recorded as ${ok ? "passing" : "FAILING"}`);
process.exit(ok ? 0 : 1);
