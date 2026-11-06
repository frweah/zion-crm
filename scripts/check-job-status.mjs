/**
 * Where an application got to, checked (0270, 0322).
 *
 *   node scripts/check-job-status.mjs
 *
 * There is one vocabulary now. For a month there were two - the nine in
 * `job_status_history` and eight different words in `lead_matches.status` -
 * with `lead_status_for_application` translating between them, and the
 * translation was lossy in the direction it ran: 'No response' and 'Applied'
 * both came out as 'Applied', so the leads board showed two hundred
 * applications as live that the practice had recorded as dead ends.
 *
 * So what this asks is no longer "do the two agree". It is **that there is
 * only one**: the ten words `lead_matches.status` accepts are 'Saved' and the
 * nine, nothing maps between vocabularies any more, and every one of the ten
 * has a rank to sort by, a note type to file under and a sentence to put on
 * the client's record. A word with no sentence is a note reading
 * "Interviewed — Warehouse at Smiths" where the others read English, and a
 * word with no rank sorts to the bottom of the board with the unknowns.
 */
import { readFile, readdir } from "node:fs/promises";
import { APPLICATION_STATUSES, JOB_STATUSES, JOB_DONE, NOTE_TYPES, NO_REPLY_DAYS } from "../lib/constants.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const DIR = new URL("../supabase/migrations/", import.meta.url);
const names = (await readdir(DIR)).filter((n) => n.endsWith(".sql")).sort();

/** The newest migration that declares the thing, which is the live one. */
async function newestDeclaring(pattern) {
  for (const name of [...names].reverse()) {
    const text = await readFile(new URL(name, DIR), "utf8");
    if (pattern.test(text)) return { name, text };
  }
  return null;
}

/** A function's own body, from its header to its closing $$ - never the file. */
function bodyOf(text, name) {
  const at = text.indexOf(`function public.${name}`);
  if (at < 0) return null;
  const end = text.indexOf("$$;", at);
  return text.slice(at, end < 0 ? undefined : end);
}

/** The words inside the first `status in (...)` of a check constraint. */
function wordsInCheck(text, pattern) {
  const block = text.match(pattern);
  if (!block) return null;
  return [...block[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
}

// ── 1. the nine in the list are the nine in the history's constraint ──
const table = await newestDeclaring(/create table if not exists public\.job_status_history/);
if (!table) {
  fail("no migration creates job_status_history, so nothing holds the nine statuses");
} else {
  const inSql = wordsInCheck(table.text, /status\s+text not null check \(status in \(([\s\S]*?)\)\)/);
  if (!inSql) {
    fail(`${table.name} creates job_status_history with no check constraint on its status`);
  } else {
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

// ── 2. and the job's own column accepts those nine and Saved ─────────
//
// The whole of the unification is in this assertion. A tenth word added to one
// side and not the other is the two vocabularies starting again.
const matches = await newestDeclaring(/add constraint lead_matches_status_check/);
if (!matches) {
  fail("nothing constrains lead_matches.status, so the board can hold any word at all");
} else {
  const inSql = wordsInCheck(matches.text, /constraint lead_matches_status_check\s*\n?\s*check \(status in \(([\s\S]*?)\)\)/);
  if (!inSql) {
    fail(`${matches.name} names lead_matches_status_check and does not say which words it accepts`);
  } else {
    const missing = JOB_STATUSES.filter((s) => !inSql.includes(s));
    const extra = inSql.filter((s) => !JOB_STATUSES.includes(s));
    if (missing.length) {
      fail(`the board offers ${missing.join(", ")} and lead_matches.status refuses them`);
    } else if (extra.length) {
      fail(`lead_matches.status accepts ${extra.join(", ")} and no screen offers them`);
    } else if (!JOB_STATUSES.includes("Saved")) {
      fail("a job somebody saved to try has no word, so it would have to be recorded as applied for");
    } else {
      ok(`lead_matches.status accepts the nine and Saved, and nothing else`);
    }
  }
}

// ── 3. nothing translates between vocabularies, because there is one ──
//
// Asked of the newest migration mentioning it rather than of the whole
// history: 0270 created the mapping and 0322 dropped it, and both are on
// disk for ever.
const mapping = await newestDeclaring(/lead_status_for_application/);
if (mapping && !/drop function if exists public\.lead_status_for_application/.test(mapping.text)) {
  fail(
    `${mapping.name} is the last word on lead_status_for_application and it does not drop it - ` +
      `two vocabularies with a translation between them is what 0322 removed`,
  );
} else {
  ok("nothing maps one job vocabulary onto another, because there is only one");
}

// ── 4. every one of the ten sorts, files and reads as English ─────────
const rank = await newestDeclaring(/function public\.job_status_rank/);
if (!rank) {
  fail("nothing ranks a job status, so the board has no order to sort by");
} else {
  const body = bodyOf(rank.text, "job_status_rank");
  const ranked = new Map([...body.matchAll(/when '([^']+)'\s+then (\d+)/g)].map((m) => [m[1], Number(m[2])]));
  const unranked = JOB_STATUSES.filter((s) => !ranked.has(s));
  const ranks = JOB_STATUSES.map((s) => ranked.get(s));
  if (unranked.length) {
    fail(`${unranked.join(", ")} has no rank, so it sorts to the bottom of the board with the unknowns`);
  } else if (new Set(ranks).size !== ranks.length) {
    fail("two job statuses share a rank, so the board's order between them is whatever the database felt like");
  } else {
    ok(`all ${JOB_STATUSES.length} job statuses have a rank of their own`);
  }
}

const noteType = await newestDeclaring(/function public\.note_type_for_match/);
if (!noteType) {
  fail("nothing says which kind of note a job status writes, and USOR 96 autofill reads the kind");
} else {
  const body = bodyOf(noteType.text, "note_type_for_match");
  const arms = [...body.matchAll(/when '([^']+)'\s+then '([^']+)'/g)];
  const fallback = /else '([^']+)'/.exec(body);
  const typeOf = (s) => arms.find(([, w]) => w === s)?.[2] ?? fallback?.[1];
  const wrong = JOB_STATUSES.map((s) => [s, typeOf(s)]).filter(([, t]) => !NOTE_TYPES.includes(t));
  if (!fallback) {
    fail("note_type_for_match has no else, so a status it has not been taught writes a note with no kind");
  } else if (wrong.length) {
    fail(
      `${wrong.map(([s, t]) => `${s} → ${t}`).join(", ")} is not a kind of note the practice has, ` +
        `so the note would be refused`,
    );
  } else {
    ok("every job status files its note under one of the kinds USOR 96 autofill reads");
  }
}

const note = await newestDeclaring(/function public\.log_lead_match/);
if (!note) {
  fail("nothing writes a note when a job moves, so the client's record would not show it");
} else {
  const body = bodyOf(note.text, "log_lead_match");
  const said = new Set([...body.matchAll(/when '([^']+)'\s+then/g)].map((m) => m[1]));
  const silent = JOB_STATUSES.filter((s) => !said.has(s));
  if (silent.length) {
    fail(
      `${silent.join(", ")} has no sentence, so the note on the client's record would read ` +
        `"${silent[0]} — <job> at <employer>" where every other one reads English`,
    );
  } else {
    ok("every job status has a sentence to put on the client's record");
  }
}

// ── 5. a job that is over is one of the words the column accepts ──────
const notAWord = JOB_DONE.filter((s) => !JOB_STATUSES.includes(s));
if (notAWord.length) {
  fail(`${notAWord.join(", ")} is called finished and is not a status a job can hold`);
} else if (JOB_DONE.includes("No response")) {
  fail(
    "silence counts as finished, so an application nobody answered would stop being chased " +
      "and would never be asked about again",
  );
} else {
  ok("the statuses that end a job are words a job can hold, and silence is not one of them");
}

// ── 6. the sweep is wired to something that runs ─────────────────────
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

// ── 7. and the report reads the history, not the three dates ─────────
const report = await readFile(new URL("../lib/report-period.ts", import.meta.url), "utf8");
if (!report.includes("client_application_status")) {
  fail("the monthly report still reads applied_on / interview_on / decided_on, so six of the nine statuses are in no report");
} else {
  ok("the monthly report reads where each application got to");
}

// ── 8. the history is added to, never changed ────────────────────────
// Asserted here as well as in verify_job_lead_status.sql, because that script
// needs the database and this one gates the build. What it can check without
// a connection is that the trigger is still declared at all.
if (table) {
  // The trigger function's own body, not the file. The section above it is
  // headed "Added to, never changed or removed", so searching the file found
  // the phrase in a comment and passed with the exception message rewritten.
  const fn = bodyOf(table.text, "job_status_history_append_only()") ?? "";
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
