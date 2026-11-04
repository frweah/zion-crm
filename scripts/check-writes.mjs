/**
 * A write a signed-in person cannot make (0285).
 *
 *   node scripts/check-writes.mjs
 *
 * `sms_messages` carried a restrictive UPDATE policy and nothing permissive. A
 * restrictive policy only ever subtracts, so with no permissive policy for the
 * command every update by a staff member matched no rows - and matching no
 * rows is not an error. PostgREST reported success and the code carried on.
 *
 * It cost a week of texts recorded as still sending while the clients had them
 * in their hands, a scheduled text that went out after somebody cancelled it,
 * and a document on a staff file whose row was left pointing at bytes the same
 * action had just deleted.
 *
 * None of it showed up as a failure anywhere, which is why this is a check
 * rather than a convention. Every direct write in `app/` and `lib/` is read
 * against what the database actually permits:
 *
 *   * a write through `createAdminClient()` runs as the service role and
 *     bypasses RLS, so it is not asked about;
 *   * a write anywhere else has to have a permissive policy for that command,
 *     or it is a write that will quietly do nothing.
 *
 * The permissions come from `lib/rls-writes.json`, which `gen-types.mjs`
 * writes, because this runs on Vercel where there are no database credentials.
 * When the credentials are here - which is every local build, and so every
 * build where the schema is being changed - the snapshot is re-derived and
 * compared. When they are not, this says so rather than implying it checked.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const snapshot = JSON.parse(readFileSync("lib/rls-writes.json", "utf8"));
const allowed = snapshot.allowed ?? {};

/**
 * A write that is deliberately not the browser's to make, with what does it
 * instead.
 *
 * Each of these is a direct write the code makes knowingly through a client
 * that bypasses RLS, or one the check cannot read correctly. Being here is a
 * decision somebody took, written where the next person will read it - not a
 * way to be forgotten.
 */
const DELIBERATE = {
  // Nothing yet. A line here should name the file, the table and the reason.
};

/** `.upsert()` is an insert as far as a policy is concerned. */
const AS_COMMAND = { update: "update", delete: "delete", insert: "insert", upsert: "insert" };

function sources(dir, found = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== ".next") sources(path, found);
    } else if (name.endsWith(".ts") || name.endsWith(".tsx")) {
      found.push(path);
    }
  }
  return found;
}

let read = 0;
let checked = 0;

for (const path of [...sources("app"), ...sources("lib")]) {
  const src = readFileSync(path, "utf8");
  read += 1;

  // A file that can reach for the service role is not asked about: that client
  // bypasses RLS, which is the whole reason the cron can record a text.
  const bypasses = src.includes("createAdminClient");

  for (const m of src.matchAll(/\.from\(\s*"([a-z_]+)"\s*\)/g)) {
    const table = m[1];
    // The operation is whichever comes first after `.from(...)`. A `.select()`
    // in between means this is a read, and a read is not this file's business:
    // without that, the next chain's `.update()` is read as this one's and the
    // check reports a table nobody writes.
    const after = src.slice(m.index + m[0].length, m.index + m[0].length + 400);
    const op = after.match(/\.(select|update|delete|insert|upsert)\(/);
    if (!op || op[1] === "select") continue;

    const command = AS_COMMAND[op[1]];
    if (bypasses) continue;

    const key = `${path.replace(/\\/g, "/")}:${table}.${command}`;
    if (DELIBERATE[key]) continue;

    checked += 1;
    const can = allowed[table];
    if (!can) {
      // Not in the snapshot at all: either RLS is off, or `authenticated` has
      // no grant. Both mean this write does not work from a screen, and the
      // two read the same from here, so the message says what is known.
      fail(
        `${path} writes ${table} (${command}) and nothing in the snapshot says a signed-in person may. ` +
          `Either it needs a permissive policy, or the write belongs in a function.`,
      );
    } else if (!can.includes(command)) {
      fail(
        `${path} does ${table}.${command}(), which has no permissive policy, so it matches no rows and ` +
          `reports success. A signed-in person may only ${can.join(", ")} on that table.`,
      );
    }
  }
}

if (checked === 0) {
  fail("no direct write was found in app/ or lib/, so this check proves nothing");
} else if (problems.length === 0) {
  ok(`all ${checked} direct writes in ${read} files are writes a signed-in person can really make`);
}

// ── and the snapshot still describes the database ────────────
//
// A snapshot is worth what its freshness is worth. This runs where the
// credentials are and says so where they are not, because a check that cannot
// get an answer must not report the answer "yes" (CLAUDE.md).
if (process.env.SUPABASE_DB_HOST && process.env.SUPABASE_DB_PASSWORD) {
  const pg = await import("pg");
  const client = new pg.default.Client({
    host: process.env.SUPABASE_DB_HOST,
    port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
    user: process.env.SUPABASE_DB_USER ?? "postgres",
    password: process.env.SUPABASE_DB_PASSWORD,
    database: process.env.SUPABASE_DB_NAME ?? "postgres",
    ssl: { rejectUnauthorized: false },
  });
  await client.connect();
  const { rows } = await client.query(`
    select c.relname, x.cmd
      from pg_class c
      join pg_namespace n on n.oid = c.relnamespace
      cross join lateral (
        select cmd, letter, priv from (values
          ('select','r','SELECT'), ('insert','a','INSERT'),
          ('update','w','UPDATE'), ('delete','d','DELETE')) as t(cmd, letter, priv)
      ) x
     where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
       and has_table_privilege('authenticated', c.oid, x.priv)
       and exists (select 1 from pg_policy p
                    where p.polrelid = c.oid and p.polpermissive
                      and p.polcmd in (x.letter, '*'))
     order by c.relname, x.cmd
  `);
  await client.end();

  const live = {};
  for (const r of rows) (live[r.relname] ??= []).push(r.cmd);

  const drifted = [];
  for (const table of new Set([...Object.keys(live), ...Object.keys(allowed)])) {
    const a = (allowed[table] ?? []).join(",");
    const b = (live[table] ?? []).join(",");
    if (a !== b) drifted.push(`${table}: snapshot says [${a}], the database says [${b}]`);
  }

  if (drifted.length) {
    fail(
      `lib/rls-writes.json no longer describes the database, so the writes above were read against ` +
        `something that is not true any more. Run scripts/gen-types.mjs. ${drifted.slice(0, 6).join("; ")}` +
        (drifted.length > 6 ? ` (and ${drifted.length - 6} more)` : ""),
    );
  } else {
    ok(`the snapshot still describes the database (${Object.keys(live).length} tables, re-derived just now)`);
  }
} else {
  ok(`the snapshot was read as written (no database credentials here, so it was not re-derived)`);
}

if (problems.length) {
  console.error("\nFAILED");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- WRITES VERIFIED ---");
