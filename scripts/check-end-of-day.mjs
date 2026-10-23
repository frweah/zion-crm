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
      -- 'Job Placement' since the stage rename (0223). It was 'Placement',
      -- and this script is run by hand, so it had been failing on the
      -- constraint quietly ever since.
      values ('ZZ Smoke Client', 'Job Placement', 'Active') returning id
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

  // ── a multi-line note, unchanged all the way round ───────
  //
  // The owner's test (23 Oct 2026, from Rei): a note with line breaks and
  // indentation in it has to come back the way it went in - out of the
  // database, through a reopen, and inside the email.
  //
  // The note below is deliberately awkward: a leading space on its first
  // line, two levels of indentation, a blank line in the middle, and a
  // trailing space. Every one of those is something `trim()` or a
  // single-line input used to destroy.
  const NOTE = [
    " Rang the counselor and left a message.",
    "    - she is back on Thursday",
    "      - try the office line first",
    "",
    "  Chasing the signed intake tomorrow. ",
  ].join("\n");
  const BOTTLENECK = ["Two things held it up:", "  1. the printer", "  2. the authorization"].join("\n");

  await client.query("select public.reopen_staff_day($1, 'Adding the detail Rei asked for.')", [dayId]);

  const { rows: written } = await client.query(
    `insert into public.staff_day_lines (day_id, status, description, notes, sort_order)
     values ($1, 'In-Progress', $2, $3, 2) returning id`,
    [dayId, "ZZ a task\n  with a second line", NOTE],
  );
  await client.query(`update public.staff_days set bottlenecks = $2 where id = $1`, [dayId, BOTTLENECK]);

  // Out of the database, as the screen reads it.
  const { rows: read } = await client.query(
    `select l.description, l.notes, d.bottlenecks
       from public.staff_day_lines l join public.staff_days d on d.id = l.day_id
      where l.id = $1`,
    [written[0].id],
  );
  if (read[0].notes !== NOTE) {
    fail(`the note came back changed:\n      wanted ${JSON.stringify(NOTE)}\n      got    ${JSON.stringify(read[0].notes)}`);
  } else if (read[0].description !== "ZZ a task\n  with a second line") {
    fail(`the description came back changed: ${JSON.stringify(read[0].description)}`);
  } else if (read[0].bottlenecks !== BOTTLENECK) {
    fail(`the bottlenecks came back changed: ${JSON.stringify(read[0].bottlenecks)}`);
  } else {
    ok("a note with line breaks, indentation and a blank line survives save and reopen");
  }

  // And inside the email, byte for byte. A substring test rather than a
  // comparison of the whole message: what has to be unchanged is the note,
  // and the summary has headings around it.
  const { rows: again } = await client.query("select public.submit_staff_day($1) as summary", [dayId]);
  const resent = again[0].summary ?? "";
  const notInEmail = [
    ["the note", NOTE],
    ["the two-line description", "ZZ a task\n  with a second line"],
    ["the bottlenecks", BOTTLENECK],
  ].filter(([, text]) => !resent.includes(text));
  if (notInEmail.length > 0) {
    fail(
      `the summary email does not carry ${notInEmail.map(([what]) => what).join(", ")} as written` +
        `\n      summary was:\n${resent.split("\n").map((l) => `      | ${l}`).join("\n")}`,
    );
  } else {
    ok("and goes into the summary email exactly as it was typed");
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
