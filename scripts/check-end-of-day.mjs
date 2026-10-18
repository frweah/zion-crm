/**
 * A Job Search person submits a day, and the client hears about it.
 *
 *   node --env-file=.env.local scripts/check-end-of-day.mjs
 *
 * The owner's smoke case, run where it can be run honestly. scripts/smoke.mjs
 * opens pages and asserts they do not break; it does not post anything, and
 * driving a server action over HTTP is brittle. More to the point, a smoke
 * test that really submitted a day would put a junk end-of-day on a real
 * client's record and a junk email in service@ on every single deploy.
 *
 * So this runs the real flow — open_staff_day, the line, submit_staff_day —
 * as a real Job Search user with RLS applied, against ZZ fixtures, inside a
 * transaction that is rolled back. Nothing is left behind and nothing is
 * emailed.
 *
 * The one piece it cannot run is the sending itself, which lives in the
 * server action. What it checks instead is that the action sends exactly one
 * message, to the address the owner named, and that the summary the message
 * carries says what it should. That part is read from the source and is
 * marked as such below.
 *
 * (The screen itself is covered by smoke.mjs already: /end-of-day is on every
 * role's navigation, so the sweep opens it for a Job Search user on every
 * deploy.)
 */
import pg from "pg";
import { readFileSync } from "node:fs";

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

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const client = new pg.Client(config);
await client.connect();

try {
  await client.query("begin");

  const { rows: setup } = await client.query(`
    with person as (
      insert into public.staff (name, email, role, active)
      values ('ZZ Smoke Coach', 'zz-smoke-coach@example.test', 'Job Search', true)
      returning id
    ),
    account as (
      insert into auth.users (id, instance_id, aud, role, email,
                              raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
      values (gen_random_uuid(), '00000000-0000-0000-0000-000000000000',
              'authenticated', 'authenticated', 'zz-smoke-coach@example.test',
              '{}', '{}', now(), now())
      returning id
    ),
    linked as (
      update public.staff set user_id = (select id from account)
       where id = (select id from person) returning id
    ),
    fixture as (
      insert into public.clients (name, stage, status)
      values ('ZZ Smoke Client', 'Placement', 'Active') returning id
    )
    select (select id from linked) as staff_id,
           (select id from account) as user_id,
           (select id from fixture) as client_id`);

  const { staff_id: staffId, user_id: userId, client_id: clientId } = setup[0];

  // From here on, as that person, with RLS applied — not as the service role.
  await client.query("select set_config('role', 'authenticated', true)");
  await client.query("select set_config('request.jwt.claims', $1, true)", [
    JSON.stringify({ sub: userId, role: "authenticated" }),
  ]);

  const { rows: opened } = await client.query("select public.open_staff_day(null) as id");
  const dayId = opened[0].id;
  ok("a Job Search person opens today's end of day");

  await client.query(
    `insert into public.staff_day_lines (day_id, status, description, notes, client_id, sort_order)
     values ($1, 'Complete', 'ZZ job club and a mock interview', 'ZZ went well', $2, 1)`,
    [dayId, clientId],
  );

  const { rows: submitted } = await client.query("select public.submit_staff_day($1) as summary", [
    dayId,
  ]);
  const summary = submitted[0].summary ?? "";
  ok("and submits it");

  // ── the client's record shows it ──────────────────────────
  const { rows: logged } = await client.query(
    `select topic, outcome, method, date from public.contact_log
      where client_id = $1 and method = 'End of day report'`,
    [clientId],
  );
  if (logged.length !== 1) {
    fail(`the client's contact log has ${logged.length} entries from the day, not 1`);
  } else if (logged[0].topic !== "ZZ job club and a mock interview") {
    fail(`the client's contact log says "${logged[0].topic}"`);
  } else {
    ok(`the client's contact log shows the line, once ("${logged[0].topic}")`);
  }

  // ── the summary the email carries ─────────────────────────
  const wanted = [
    ["the heading", "END OF THE DAY REPORT"],
    ["who it is from", "ZZ Smoke Coach"],
    ["the task line", "ZZ job club and a mock interview"],
    ["the client it was about", "ZZ Smoke Client"],
    ["the bottlenecks heading", "BOTTLENECKS"],
    ["the actions heading", "ACTIONS TAKEN/SUGGESTIONS"],
  ];
  const missing = wanted.filter(([, text]) => !summary.includes(text));
  if (missing.length) {
    fail(`the summary is missing ${missing.map(([what]) => what).join(", ")}`);
  } else {
    ok("and the summary carries the template's headings, the task and the client");
  }

  await client.query("rollback");
  ok("nothing was kept: the whole run is rolled back");
} catch (err) {
  await client.query("rollback").catch(() => {});
  fail(`the run failed: ${err.message}`);
} finally {
  await client.end();
}

// ── one email, to the address the owner named ────────────────
// Read from the source rather than sent, because sending it is the one step
// this script must not take.
const action = readFileSync(new URL("../app/(app)/end-of-day/actions.ts", import.meta.url), "utf8");
const submitBody = action.slice(action.indexOf("export async function submitDay"));
const sends = [...submitBody.matchAll(/sendEmail\(/g)].length;

if (sends !== 1) {
  fail(`submitting a day sends ${sends} emails; the owner asked for one summary`);
} else if (!/const DAYS_TO = "service@zionvocrehab\.com"/.test(action)) {
  fail("the summary does not go to service@zionvocrehab.com");
} else if (!/to: DAYS_TO/.test(submitBody)) {
  fail("the one email submitting sends does not go to DAYS_TO");
} else {
  ok("submitting sends exactly one email, to service@zionvocrehab.com");
}

if (problems.length > 0) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log("--- END OF DAY SMOKE VERIFIED ---");
