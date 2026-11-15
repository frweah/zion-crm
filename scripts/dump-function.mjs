/**
 * What the database actually holds for a function, written to a file.
 *
 *   node --env-file=.env.local scripts/dump-function.mjs <out-dir> <name>...
 *
 * A replacement built from the migration that last created a function is a
 * replacement built on the wrong thing: the database drifts, and more than one
 * migration has quietly reverted a later fix by re-stating an earlier body.
 * This dumps `pg_get_functiondef` so a `create or replace` starts from what is
 * live. One file per function, named for it; an overload gets a numbered file
 * each, because a defaulted argument makes a second function rather than
 * changing the first.
 */
import { writeFileSync, mkdirSync } from "node:fs";
import pg from "pg";

const config = {
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
  connectionTimeoutMillis: 20000,
};

if (!config.host || !config.password) {
  console.error("SUPABASE_DB_HOST and SUPABASE_DB_PASSWORD must be set in .env.local");
  process.exit(1);
}

const [out, ...names] = process.argv.slice(2);
if (!out || names.length === 0) {
  console.error("Usage: node --env-file=.env.local scripts/dump-function.mjs <out-dir> <name>...");
  process.exit(1);
}

mkdirSync(out, { recursive: true });
const client = new pg.Client(config);
await client.connect();
let missing = 0;
for (const name of names) {
  const { rows } = await client.query(
    `select pg_get_functiondef(p.oid) as def,
            pg_get_function_identity_arguments(p.oid) as args
       from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
      where ns.nspname = 'public' and p.proname = $1
      order by p.oid`,
    [name],
  );
  if (rows.length === 0) {
    // A view, for the same reason: a column has to come out of one now and
    // then, and `create or replace view` cannot do it - the whole definition
    // has to be restated, so it had better be restated from what is live.
    const { rows: views } = await client.query(
      `select pg_get_viewdef(c.oid, true) as def,
              coalesce((select o.option_value from pg_options_to_table(c.reloptions) o
                         where o.option_name = 'security_invoker'), 'definer') as mode
         from pg_class c join pg_namespace ns on ns.oid = c.relnamespace
        where ns.nspname = 'public' and c.relkind = 'v' and c.relname = $1`,
      [name],
    );
    if (views.length === 1) {
      const path = `${out}/${name}.sql`;
      writeFileSync(path, views[0].def, "utf8");
      console.log(`  ${path}  ${views[0].def.split("\n").length} lines  (view, ${views[0].mode})`);
      continue;
    }
    console.log(`  not in the database: ${name}`);
    missing += 1;
    continue;
  }
  rows.forEach((r, i) => {
    const path = `${out}/${name}${rows.length > 1 ? `_${i}` : ""}.sql`;
    writeFileSync(path, r.def, "utf8");
    console.log(`  ${path}  ${r.def.split("\n").length} lines  (${r.args || "no arguments"})`);
  });
}
await client.end();
process.exit(missing ? 1 : 0);
