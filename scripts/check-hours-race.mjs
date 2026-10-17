/**
 * Two people logging hours against the same authorization at the same moment.
 *
 *   node --env-file=.env.local scripts/check-hours-race.mjs
 *
 * This is the one thing the verify suite cannot say. check_entry_hours counts
 * the hours used and then decides whether one more entry fits; before 0208
 * nothing held the authorization in between, so two sessions could both read
 * the same figure, both find room and both get in. The suite runs in a single
 * session, and a single session never waits for itself — so the assertion it
 * can make is about the text of the function, which is the kind of check that
 * passes the bug it was written for.
 *
 * So this opens two connections and has them race, for real.
 *
 * Nothing is written. Both transactions roll back, and the second one is
 * given a two-second lock timeout so a correct database makes it give up
 * rather than hang. What it proves:
 *
 *   With the lock in place, the second session cannot get in while the first
 *   is still deciding. It waits, and times out.
 *
 *   And two sessions logging against *different* authorizations do not wait
 *   for each other at all. That is the control, and it is the part that
 *   stops the first result being mistaken for the two sessions simply
 *   contending over something — the waiting is specific to the authorization
 *   whose hours are being counted, which is what the lock is for.
 *
 * Taking the lock back out and watching both get in would be the stronger
 * control, and it cannot be done from here: replacing the function inside the
 * first transaction makes the second session wait on the catalogue rather
 * than on the row, so it blocks for the wrong reason and the test would pass
 * while proving nothing. verify_hours_race.sql carries that half instead.
 *
 * It needs an hourly authorization with hours left to race on, and it reads
 * one rather than creating one, because a row created by either session is
 * invisible to the other until it commits and nothing here commits.
 */
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

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);


const connect = async () => {
  const c = new pg.Client(config);
  await c.connect();
  return c;
};

/**
 * Both sessions log the hours that are left, at the same time. One of them
 * has to be refused or made to wait; two getting in is the bug.
 *
 * Returns what happened to the second session.
 */
async function race(a, b, authA, authB, hoursEach) {
  await a.query("begin");
  await b.query("begin");
  try {
    // The first session logs, and then sits there without committing —
    // which is exactly the window the race lives in.
    await a.query(
      `insert into public.service_entries (auth_id, date, hours, staff_id, notes)
       values ($1, $3, $2, null, 'ZZ race check A')`,
      [authA.id, hoursEach, authA.on_date],
    );

    // The second session tries the same thing. Two seconds is long enough to
    // tell waiting from not waiting, and short enough not to hang a build.
    await b.query("set local lock_timeout = '2s'");
    try {
      await b.query(
        `insert into public.service_entries (auth_id, date, hours, staff_id, notes)
         values ($1, $3, $2, null, 'ZZ race check B')`,
        [authB.id, Math.min(hoursEach, Number(authB.total_hours) - Number(authB.used)), authB.on_date],
      );
      return { secondGotIn: true, code: null };
    } catch (err) {
      return { secondGotIn: false, code: err.code, message: err.message };
    }
  } finally {
    await a.query("rollback");
    await b.query("rollback");
  }
}

const a = await connect();
const b = await connect();

try {
  // An hourly authorization with room left, and how much room.
  const { rows } = await a.query(`
    select r.id, r.number, r.total_hours, u.used, r.on_date
      from (
        select a.id, a.number, a.total_hours,
               -- A date inside the authorization's own period that has
               -- already happened: check_entry_in_dates refuses anything
               -- outside it, and check_entry_hours refuses the future.
               least(coalesce(a.end_date, public.practice_today()), public.practice_today()) as on_date
          from public.authorizations a
         where a.total_hours is not null
           and a.parent_id is null
           and a.status not in ('Paid', 'Closed')
           and not a.is_placeholder
           and a.start_date is not null
           and a.start_date <= public.practice_today()
           and least(coalesce(a.end_date, public.practice_today()), public.practice_today()) >= a.start_date
         order by a.created_at
      ) r
      join public.authorization_hours_used(array(
        select a2.id from public.authorizations a2
         where a2.total_hours is not null and a2.parent_id is null
      )) u on u.auth_id = r.id
     where r.total_hours - u.used >= 2
     order by r.total_hours - u.used desc
     limit 2`);

  if (rows.length === 0) {
    console.log("");
    console.log("  --  no hourly authorization with two hours left to race on; nothing checked");
    console.log("");
    process.exit(0);
  }

  const auth = rows[0];
  const left = Number(auth.total_hours) - Number(auth.used);
  // Each session logs all of the hours that are left, so exactly one of them
  // can be right.
  const each = left;

  // ── the same authorization: one of them has to wait ───────
  const shared = await race(a, b, auth, auth, each);
  if (shared.secondGotIn) {
    fail(
      `two sessions both logged ${each} hours against ${auth.number || auth.id} with only ${left} left. ` +
        `The authorization is not held while its hours are counted.`,
    );
  } else if (shared.code === "55P03" || /lock/i.test(shared.message ?? "")) {
    ok(`two sessions logging against one authorization: the second waits and gives up (${shared.code})`);
  } else {
    ok(`two sessions logging against one authorization: the second is refused (${shared.code})`);
  }

  // ── different authorizations: neither waits ───────────────
  if (rows.length < 2) {
    console.log("  --  only one hourly authorization with hours left, so the control was not run");
  } else {
    const other = rows[1];
    const apart = await race(a, b, auth, other, each);
    if (apart.secondGotIn) {
      ok("two sessions logging against different authorizations do not wait for each other");
    } else {
      fail(
        "two sessions logging against different authorizations still blocked each other " +
          `(${apart.code}: ${apart.message}), so the waiting above is not about the authorization`,
      );
    }
  }
} finally {
  await a.end();
  await b.end();
}

if (problems.length > 0) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log("--- HOURS RACE VERIFIED ---");
