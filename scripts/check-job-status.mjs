/**
 * Where an application got to, checked (0270).
 *
 *   node scripts/check-job-status.mjs
 *
 * An application's status lives in two vocabularies at once, and will until
 * the owner decides whether to collapse them:
 *
 *   the nine, in `job_status_history` — Applied, Employer responded, Interview
 *   scheduled, Interviewed, Offer, Hired, Declined by employer, Client
 *   withdrew, No response;
 *
 *   the eight, in `lead_matches.status` — Saved, Applied, Follow-up,
 *   Interview, Offer, Hired, Not selected, Withdrawn, which seven database
 *   functions, four views and the leads board read.
 *
 * Two vocabularies for one thing is exactly what drifts, so the places they
 * are written down are asked rather than trusted: the nine in `lib/constants`
 * against the nine in the migration's check constraint, and every one of the
 * nine against a word in the mapping. A tenth status added to the list and not
 * to the constraint is a screen offering something the database refuses.
 *
 * `lead_status_for_application` is the only place the two meet. A second place
 * would be a second answer.
 */
import { readFile, readdir } from "node:fs/promises";
import { APPLICATION_STATUSES, JOB_STATUSES, NO_REPLY_DAYS } from "../lib/constants.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const DIR = new URL("../supabase/migrations/", import.meta.url);

/** The newest migration that declares the thing, which is the live one. */
async function newestDeclaring(pattern) {
  const names = (await readdir(DIR)).filter((n) => n.endsWith(".sql")).sort();
  for (const name of names.reverse()) {
    const text = await readFile(new URL(name, DIR), "utf8");
    if (pattern.test(text)) return { name, text };
  }
  return null;
}

// ── the nine in the list are the nine in the constraint ──────
const table = await newestDeclaring(/create table if not exists public\.job_status_history/);
if (!table) {
  fail("no migration creates job_status_history, so nothing holds the nine statuses");
} else {
  const block = table.text.match(/status\s+text not null check \(status in \(([\s\S]*?)\)\)/);
  if (!block) {
    fail(`${table.name} creates job_status_history with no check constraint on its status`);
  } else {
    const inSql = [...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
    const missing = APPLICATION_STATUSES.filter((s) => !inSql.includes(s));
    const extra = inSql.filter((s) => !APPLICATION_STATUSES.includes(s));
    if (missing.length) {
      fail(`the screen offers ${missing.join(", ")} and the database refuses them`);
    } else if (extra.length) {
      fail(`the database accepts ${extra.join(", ")} and no screen offers them`);
    } else if (inSql.length !== 9) {
      fail(`there are ${inSql.length} application statuses and the owner listed nine`);
    } else {
      ok(`all ${inSql.length} application statuses are offered and accepted`);
    }
  }
}

// ── and every one of them has a word in the other vocabulary ──
const map = await newestDeclaring(/function public\.lead_status_for_application/);
if (!map) {
  fail("nothing maps an application status onto the word lead_matches.status carries");
} else {
  // The function's own body, not everything after the first mention of its
  // name — the migration names it in its header comment, and the seed below
  // has a CASE of its own mapping the other way. Reading from the comment
  // picked up the seed's arms and reported the mapping backwards.
  const start = map.text.indexOf("create or replace function public.lead_status_for_application");
  const body = map.text.slice(start, map.text.indexOf("$$;", start));
  const arms = [...body.matchAll(/when '([^']+)'\s+then '([^']+)'/g)];
  const seen = new Map(arms.map((m) => [m[1], m[2]]));

  const unmapped = APPLICATION_STATUSES.filter((s) => !seen.has(s));
  if (unmapped.length) {
    fail(
      `${unmapped.join(", ")} would leave lead_matches.status null, and the leads board reads it`,
    );
  } else {
    ok("every application status says what the leads board should read");
  }

  // The other end of the same rule: what it maps *to* has to be a word the
  // eight-value constraint on lead_matches accepts. This is the half that
  // breaks silently - a mapping to "Rejected" would pass every assertion
  // above and fail on the first person to record one.
  const wrong = [...seen.entries()].filter(([, word]) => !JOB_STATUSES.includes(word));
  if (wrong.length) {
    fail(
      `maps to ${wrong.map(([s, w]) => `${s} → ${w}`).join(", ")}, which lead_matches.status does not accept`,
    );
  } else {
    ok("and that word is one lead_matches.status accepts");
  }
}

// ── the sweep is wired to something that runs ────────────────
// A rule nothing calls is a rule that does not happen, which is the whole
// subject of check-checks. The fourteen days are named once, in lib/constants,
// so the route and the screen cannot disagree about how long silence is.
const chase = await readFile(new URL("../app/api/cron/chase/route.ts", import.meta.url), "utf8");
// The call itself, not the file. Asking whether the file mentions
// NO_REPLY_DAYS passed with `p_days: 14` hard-coded in the call, because the
// import line still said the name — a question asked near the rule.
const call = chase.match(/mark_applications_with_no_reply"[\s\S]{0,200}?\}\)/);
if (!chase.includes("mark_applications_with_no_reply")) {
  fail("nothing calls mark_applications_with_no_reply, so No response never happens");
} else if (!call || !call[0].includes("NO_REPLY_DAYS")) {
  fail("the chase route passes its own number of days instead of NO_REPLY_DAYS");
} else if (NO_REPLY_DAYS !== 14) {
  fail(`NO_REPLY_DAYS is ${NO_REPLY_DAYS} and the owner asked for fourteen`);
} else {
  ok("the fourteen-day sweep runs daily, from one number in one place");
}

// ── and the report reads the history, not the three dates ────
const report = await readFile(new URL("../lib/report-period.ts", import.meta.url), "utf8");
if (!report.includes("client_application_status")) {
  fail("the monthly report still reads applied_on / interview_on / decided_on, so six of the nine statuses are in no report");
} else {
  ok("the monthly report reads where each application got to");
}

// ── the history is added to, never changed ───────────────────
// Asserted here as well as in verify_job_lead_status.sql, because that script
// needs the database and this one gates the build. What it can check without
// a connection is that the trigger is still declared at all.
if (table) {
  // The trigger function's own body, not the file. The section above it is
  // headed "Added to, never changed or removed", so searching the file found
  // the phrase in a comment and passed with the exception message rewritten.
  const fnAt = table.text.indexOf("function public.job_status_history_append_only()");
  const fn = fnAt < 0 ? "" : table.text.slice(fnAt, table.text.indexOf("$$;", fnAt));
  if (!/before update or delete on public\.job_status_history/.test(table.text)) {
    fail("job_status_history has no append-only trigger, so a status can be rewritten");
  } else if (!/never changed or removed/.test(fn)) {
    fail(
      "the append-only trigger does not say 'never changed or removed', which is the phrase merge_clients looks for",
    );
  } else {
    ok("the history is declared append-only, in the words the merge recognises");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- APPLICATION STATUSES VERIFIED ---");
