/**
 * A route nothing schedules is a route that does not run.
 *
 *   node scripts/check-scheduler.mjs
 *
 * The same rule as `check-checks`, about a different roster. Every route under
 * `app/api/cron/` is either scheduled - by a migration, or by an
 * `enable_*.sql` somebody runs once against the database - or named below with
 * the reason it is not. There is no third option, and adding a cron route
 * without scheduling it fails here.
 *
 * It cannot ask the database whether the job is really in `cron.job`: prebuild
 * runs on Vercel with no credentials. What it can hold is the half that rots
 * in a pull request - that the practice has written down how each route gets
 * called. `verify_scheduler.sql` asks the live scheduler.
 *
 * This was asked for by name (owner, 29 Oct 2026: "put it on the existing
 * scheduler and in check-scheduler"), and it did not exist.
 */
import { readFile, readdir } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

/**
 * The cron routes nothing schedules, each with why.
 *
 * Being on this list is not permission to be forgotten. It is a note that the
 * route is called some other way, and which way.
 */
const NOT_SCHEDULED = {
  "file-the-queue":
    "a one-off the owner runs by hand when the document queue has built up; it files the backlog by the same rules the agent runs on arrival, and running it on a timer would be a decision nobody asked for",
};

const CRON = new URL("../app/api/cron/", import.meta.url);
const routes = (await readdir(CRON, { withFileTypes: true }))
  .filter((e) => e.isDirectory())
  .map((e) => e.name)
  .sort();

// Everywhere a schedule can be written down: the migrations that schedule a
// job outright, and the enable_*.sql files that are run once by hand.
const SUPA = new URL("../supabase/", import.meta.url);
const sqlNames = (await readdir(SUPA)).filter((n) => n.endsWith(".sql"));
const MIG = new URL("../supabase/migrations/", import.meta.url);
const migNames = (await readdir(MIG)).filter((n) => n.endsWith(".sql"));

let scheduling = "";
for (const n of sqlNames) scheduling += await readFile(new URL(n, SUPA), "utf8");
for (const n of migNames) scheduling += await readFile(new URL(n, MIG), "utf8");

for (const route of routes) {
  const named = scheduling.includes(`/api/cron/${route}`);
  if (named && NOT_SCHEDULED[route]) {
    fail(`${route} is scheduled and is also listed as not scheduled, so one of the two is wrong`);
  } else if (!named && !NOT_SCHEDULED[route]) {
    fail(
      `nothing schedules /api/cron/${route}, so it never runs — schedule it in a migration or an enable_*.sql, or say here why it is called another way`,
    );
  }
}

// The other direction: a reason left behind for a route that has gone is a
// reason somebody will believe next time.
for (const route of Object.keys(NOT_SCHEDULED)) {
  if (!routes.includes(route)) {
    fail(`${route} is listed as not scheduled and there is no such route`);
  }
}

if (!problems.length) {
  const scheduled = routes.filter((r) => !NOT_SCHEDULED[r]).length;
  ok(`all ${scheduled} of ${routes.length} cron routes are scheduled somewhere`);
  ok(`${routes.length - scheduled} is called another way, with the reason`);
}

// ── every schedule points at a route that exists ─────────────
// A typo in a URL is a job that posts into nothing, every quarter hour, for
// ever. The database would show it succeeding: a 404 is a response.
const urls = [...scheduling.matchAll(/\/api\/cron\/([a-z-]+)/g)].map((m) => m[1]);
const ghosts = [...new Set(urls)].filter((u) => !routes.includes(u));
if (ghosts.length) {
  fail(`a schedule posts to /api/cron/${ghosts.join(", /api/cron/")}, which is not there`);
} else {
  ok(`all ${new Set(urls).size} scheduled URLs reach a route that exists`);
}

// ── the Monday run is Monday, twice, for one email ───────────
// Written down because it is the one schedule in the system that is not
// obvious from its own cron line: Utah moves an hour twice a year and the
// route picks whichever firing is 7 o'clock there.
const monday = await readFile(new URL("enable_monday_health.sql", SUPA), "utf8").catch(() => "");
const health = await readFile(new URL("../app/api/cron/health/route.ts", import.meta.url), "utf8").catch(() => "");
if (!monday) {
  fail("nothing enables the Monday health run");
} else if (!/'0 13,14 \* \* 1'/.test(monday)) {
  fail("the Monday health run is not scheduled at 13:00 and 14:00 UTC on a Monday, so it is not 07:00 Mountain all year");
} else if (!/America\/Denver/.test(health)) {
  fail("the health route does not read the hour in Utah, so one of the two firings sends a second email");
} else if (!/hour === 7/.test(health)) {
  fail("the health route does not hold the send to 7 o'clock in Utah");
} else {
  ok("the Monday run fires twice in UTC and sends once, at 07:00 Mountain either half of the year");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- SCHEDULER VERIFIED ---");
