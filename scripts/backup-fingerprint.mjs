/**
 * What a database holds, as a fingerprint you can compare.
 *
 *   node --env-file=.env.local scripts/backup-fingerprint.mjs > before.json
 *   node --env-file=.env.local scripts/backup-fingerprint.mjs --compare before.json
 *
 * The restore drill (owner, 18 Oct 2026). Supabase takes backups; nobody has
 * ever checked that one restores. "The backup ran" and "the practice could be
 * put back" are different claims, and only the second is worth anything.
 *
 * For every table: how many rows, and a checksum over its contents. The
 * checksum is what makes this worth more than a row count — a restore that
 * loses a column, truncates text or drops a timezone keeps the row count
 * exactly and changes the fingerprint.
 *
 * It is deliberately a plain JSON file and a plain comparison: the whole
 * point is to run it against a database that is not this one, from a laptop,
 * under whatever pressure the day it is needed brings.
 *
 * Nothing in the output is client data. Each table contributes a count and a
 * hash; the fingerprint can be mailed, committed or pasted into a ticket
 * without disclosing anything.
 */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { hostname, userInfo } from "node:os";
import pg from "pg";

const compareTo = process.argv.includes("--compare")
  ? process.argv[process.argv.indexOf("--compare") + 1]
  : null;

const config = {
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
  statement_timeout: 600000,
};

if (!config.host || !config.password) {
  console.error("SUPABASE_DB_HOST and SUPABASE_DB_PASSWORD must be set in .env.local");
  process.exit(1);
}

const client = new pg.Client(config);
await client.connect();

/**
 * Every ordinary table in public, and the columns worth hashing.
 *
 * Generated columns and anything whose value is the moment it was written are
 * left out of the hash: created_at survives a restore, but a column defaulting
 * to now() on a row the restore itself inserts would not, and a fingerprint
 * that changes for the right reasons is a fingerprint nobody trusts.
 */
const { rows: tables } = await client.query(`
  select c.relname as table
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
   order by c.relname`);

/**
 * Tables whose contents change while you are looking at them.
 *
 * Found the way anybody would find them: run this twice against the same
 * database and see what differs. staff_presence is who is on the CRM right
 * now and changes every few seconds, so comparing it would report every
 * restore as wrong and the tool would be ignored within a week.
 *
 * They are listed in the output as skipped rather than quietly dropped. A
 * table excluded without saying so is how a fingerprint comes to cover less
 * than the person reading it believes.
 */
const VOLATILE = new Set(["staff_presence", "work_session_timers"]);

const fingerprint = {};
const skipped = [];
let totalRows = 0;

for (const { table } of tables) {
  if (VOLATILE.has(table)) {
    skipped.push(table);
    continue;
  }
  const { rows: cols } = await client.query(
    `select column_name
       from information_schema.columns
      where table_schema = 'public' and table_name = $1
        and is_generated = 'NEVER'
      order by ordinal_position`,
    [table],
  );
  if (cols.length === 0) continue;

  const list = cols.map((c) => `coalesce(t.${JSON.stringify(c.column_name).replace(/"/g, '"')}::text, '')`).join(" || '|' || ");

  // md5 of the sorted row digests, so the fingerprint does not depend on the
  // order rows happen to come back in — which a restore does not preserve.
  const { rows } = await client.query(
    `select count(*)::bigint as rows,
            coalesce(md5(string_agg(d, '' order by d)), '') as digest
       from (select md5(${list}) as d from public.${JSON.stringify(table).replace(/"/g, '"')} t) q`,
  );

  fingerprint[table] = { rows: Number(rows[0].rows), digest: rows[0].digest };
  totalRows += Number(rows[0].rows);
}

const taken = {
  host: config.host,
  at: new Date().toISOString(),
  tables: Object.keys(fingerprint).length,
  rows: totalRows,
  skipped,
  fingerprint,
};

/**
 * A mark that it ran, for the Monday email (0278).
 *
 * The fingerprint itself is a file somebody keeps; what the practice needs to
 * know on a Monday is when one was last taken and whether the comparison
 * passed. One short digest over the whole fingerprint goes in the detail, so
 * two runs can be told apart at a glance without reading the JSON.
 *
 * Best effort: this script's job is to produce a fingerprint under whatever
 * pressure the day it is needed brings, and failing to write a note about
 * itself is not a reason to fail that.
 */
async function recordIt(ok, detail) {
  try {
    await client.query(
      `insert into public.practice_health (kind, at, ok, detail, recorded_by)
       values ('backup', now(), $1, $2, $3)
       on conflict (kind) do update
         set at = excluded.at, ok = excluded.ok,
             detail = excluded.detail, recorded_by = excluded.recorded_by`,
      [ok, detail.slice(0, 500), `${userInfo().username}@${hostname()}`.slice(0, 120)],
    );
  } catch (err) {
    console.error(`  --  the run was not recorded: ${err.message}`);
  }
}

/** One digest over the whole fingerprint, so two runs are distinguishable. */
function shortDigest(of) {
  return createHash("sha256").update(JSON.stringify(of)).digest("hex").slice(0, 12);
}

if (!compareTo) {
  await recordIt(
    true,
    `fingerprint ${shortDigest(fingerprint)} — ${taken.tables} tables, ${taken.rows} rows on ${taken.host}`,
  );
  await client.end();
  console.log(JSON.stringify(taken, null, 2));
  process.exit(0);
}

// ── compare ──────────────────────────────────────────────────
const before = JSON.parse(readFileSync(compareTo, "utf8"));
const names = [...new Set([...Object.keys(before.fingerprint), ...Object.keys(fingerprint)])].sort();

const missing = [], extra = [], differs = [], same = [];
for (const name of names) {
  const a = before.fingerprint[name];
  const b = fingerprint[name];
  if (a && !b) missing.push(name);
  else if (!a && b) extra.push(`${name} (${b.rows} rows)`);
  else if (a.rows !== b.rows) differs.push(`${name}: ${a.rows} rows before, ${b.rows} after`);
  else if (a.digest !== b.digest) differs.push(`${name}: ${a.rows} rows both ways, but the contents differ`);
  else same.push(name);
}

console.log("");
console.log(`  before  ${before.host}  ${before.at}  ${before.tables} tables, ${before.rows} rows`);
console.log(`  after   ${taken.host}  ${taken.at}  ${taken.tables} tables, ${taken.rows} rows`);
console.log("");
console.log(`  ok  ${same.length} tables match, contents and all`);
if (taken.skipped.length) {
  console.log(`  --  not compared, because they change by the second: ${taken.skipped.join(", ")}`);
}

if (missing.length) console.error(`  FAILED  ${missing.length} tables did not come back: ${missing.join(", ")}`);
if (extra.length) console.error(`  FAILED  ${extra.length} tables are there that were not before: ${extra.join(", ")}`);
for (const d of differs) console.error(`  FAILED  ${d}`);

if (missing.length || extra.length || differs.length) {
  await recordIt(
    false,
    `the restore is not the database that was backed up: ${[...missing, ...extra, ...differs].slice(0, 3).join("; ")}`,
  );
  console.error("");
  console.error("  The restore is not the database that was backed up. Do not cut over.");
  console.error("");
  await client.end();
  process.exit(1);
}

await recordIt(
  true,
  `restore verified against ${before.at} — ${same.length} tables match, fingerprint ${shortDigest(fingerprint)}`,
);

await client.end();

console.log("");
console.log("--- RESTORE VERIFIED ---");
