/**
 * The rule: a screen that fails is asked once more, ten seconds later, and
 * two failures in a row is a real one (owner, 20 November 2026).
 *
 * Three questions, because the rule has three halves that can each be true
 * while another is false:
 *
 *   1. the loop itself, driven over fixtures - what gets a second look, what
 *      does not, what the run is told, and what the budget does when a deploy
 *      breaks everything at once;
 *   2. the wait is ten seconds and nothing can turn it down - no environment
 *      variable, no argument from the caller;
 *   3. the deploy check is actually wired to it, every screen read goes
 *      through it, and a screen that failed once is named at the end of the
 *      run even though the run is green.
 *
 * What this cannot ask: whether the real `openOnce` labels a real 404 from
 * production as `status`. It asks the next best thing - that every failure it
 * can return carries a kind at all, by matching braces rather than by
 * grepping for sentences, because those sentences get reworded and this must
 * not fail when they do.
 */
import { readFileSync } from "node:fs";
import { AFTER_MS, BUDGET, SETTLED, askAgain, retrying } from "./retry-screen.mjs";

const problems = [];
const bad = (line) => problems.push(line);
const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");

// ── 1. the loop ───────────────────────────────────────────────
/**
 * One opener, scripted: the nth call gets the nth answer, and the last answer
 * stands for every call after it. `path` is recorded on every call, because
 * "the second look is the same look" is the thing that stops this becoming a
 * way for a broken screen to pass.
 */
function opener(...answers) {
  const asked = [];
  return {
    asked,
    open: async (path) => {
      asked.push(path);
      return { path, ...(answers[asked.length - 1] ?? answers[answers.length - 1]) };
    },
  };
}

function harness(...answers) {
  const o = opener(...answers);
  const waited = [];
  const said = [];
  const r = retrying({
    open: o.open,
    wait: async (ms) => waited.push(ms),
    say: (line) => said.push(line),
  });
  return { ...r, asked: o.asked, waited, said };
}

const ok = { ok: true, body: "<html>the second look</html>" };
const four04 = { ok: false, kind: "status", why: "HTTP 404" };
const five00 = { ok: false, kind: "status", why: "HTTP 500" };

// A screen that opens is opened once. Nothing waits, nothing is said.
{
  const h = harness(ok);
  const r = await h.open("/clients");
  if (!r.ok) bad("a screen that opened was not reported as open");
  if (h.asked.length !== 1) bad(`a screen that opened was asked ${h.asked.length} times`);
  if (h.waited.length) bad("a screen that opened still waited");
  if (h.flaky.length) bad("a screen that opened was recorded as flaky");
  if (h.lines().length) bad("a run with nothing to report still printed a retry report");
}

// A 404 then a 200: green, recorded, and the second look is the same path.
{
  const h = harness(four04, ok);
  const r = await h.open("/billing?tab=hours");
  if (!r.ok) bad("a screen that failed once and opened on the second look was still failed");
  if (h.asked.length !== 2) bad(`a failed screen was asked ${h.asked.length} times, not twice`);
  if (h.asked[0] !== h.asked[1]) bad(`the second look asked ${h.asked[1]}, not ${h.asked[0]}`);
  if (h.waited.length !== 1 || h.waited[0] !== AFTER_MS) bad(`the wait before the second look was ${h.waited.join()}, not ${AFTER_MS}`);
  if (h.flaky.length !== 1 || h.flaky[0].path !== "/billing?tab=hours") bad("the flaky screen was not recorded");
  if (h.flaky[0]?.why !== "HTTP 404") bad(`the flaky record says "${h.flaky[0]?.why}" rather than what the first look said`);
  if (r.flakyWhy !== "HTTP 404") bad("the result does not carry what the first look said, so the list cannot show it");
  if (r.body !== ok.body) bad("the result does not carry the second look's body, so callers reading the page get nothing");
  if (!h.said.some((l) => /again/.test(l))) bad("nothing was said at the moment the screen was asked again");
  if (!h.said.some((l) => /flaky/.test(l) && /billing/.test(l))) bad("the screen was not named as flaky when it opened");
  const report = h.lines().join("\n");
  if (!/::warning/.test(report)) bad("a flaky screen raised no warning on the run, so a green run hides it");
  if (!report.includes("/billing?tab=hours")) bad("the retry report does not name the flaky screen");
  if (!report.includes("HTTP 404")) bad("the retry report does not say what the screen said the first time");
}

// Twice is real. And the run is told it was asked twice, not once.
{
  const h = harness(five00, five00);
  const r = await h.open("/clients");
  if (r.ok) bad("a screen that failed twice was reported as open");
  if (h.asked.length !== 2) bad(`a screen that failed twice was asked ${h.asked.length} times`);
  if (!/twice/.test(r.why)) bad(`a screen that failed twice says "${r.why}", which does not say it was asked twice`);
  if (!/10s apart/.test(r.why)) bad(`"${r.why}" does not say how far apart the two looks were`);
  if (h.flaky.length) bad("a screen that failed twice was recorded as flaky");
}

// Two different failures: the message carries both, because "HTTP 500 twice"
// and "404 then 500" are different faults.
{
  const h = harness(four04, five00);
  const r = await h.open("/clients");
  if (!/HTTP 500/.test(r.why) || !/HTTP 404/.test(r.why)) bad(`a screen that failed two different ways says only "${r.why}"`);
}

/**
 * A screen that answers 200 and draws nothing is a screen that failed.
 *
 * The rule covered a status and not an assertion until 24 November 2026, when
 * the client threads board answered 200 with its table and without its
 * groups - one read of a function that has answered every other time - and
 * the run put production back a commit for it. So the question the caller
 * wants asked of the page is part of the look, and is asked again with it.
 */
{
  const bodies = [{ ok: true, body: "<table class=\"board\"></table>" }, { ok: true, body: "Needs a reply" }];
  const groups = (r) => (/Needs a reply/.test(r.body) ? undefined : "the board drew no groups");

  // Nothing wrong with the page: one look, no wait.
  {
    const h = harness(bodies[1]);
    const r = await h.open("/communication/threads", groups);
    if (!r.ok) bad("a page that answered the caller's question was still failed");
    if (h.asked.length !== 1) bad(`a page that answered was asked ${h.asked.length} times`);
  }

  // Wrong once, right the second time: green, and named as flaky.
  {
    const h = harness(bodies[0], bodies[1]);
    const r = await h.open("/communication/threads", groups);
    if (!r.ok) bad("a page that drew nothing once and drew it the second time was still failed");
    if (h.asked.length !== 2) bad(`a page that drew nothing was asked ${h.asked.length} times, not twice`);
    if (h.waited[0] !== AFTER_MS) bad("the second look at a page that drew nothing did not wait ten seconds");
    if (h.flaky.length !== 1) bad("a page that drew nothing once was not recorded as flaky");
    if (r.flakyWhy !== "the board drew no groups") bad("the flaky record does not say what was missing the first time");
  }

  /**
   * And wrong twice is real - which is the half that stops this becoming a
   * way for a broken screen to pass. The second look has to ask the same
   * question of the second page: a loop that ran the assertion only on the
   * first look would call every broken screen flaky and green.
   */
  {
    const h = harness(bodies[0]);
    const r = await h.open("/communication/threads", groups);
    if (r.ok) bad("a page that drew nothing twice came back open, so a broken screen passes on its second look");
    if (h.asked.length !== 2) bad(`a page that drew nothing twice was asked ${h.asked.length} times`);
    if (!/twice/.test(r.why) || !/10s apart/.test(r.why)) bad(`"${r.why}" does not say it was asked twice, ten seconds apart`);
    if (r.kind !== "in-page") bad(`a page that drew nothing is labelled "${r.kind}" rather than in-page`);
    if (h.flaky.length) bad("a page that drew nothing twice was recorded as flaky as well as failed");
  }

  // A page that did not open is not asked the question at all: there is no
  // page to ask it of, and the status is the fault worth reporting.
  {
    const h = harness(four04, four04);
    const r = await h.open("/communication/threads", () => "the board drew no groups");
    if (r.why.includes("groups")) bad("a 404 was reported as a page that drew nothing");
  }
}

// The other two kinds that are worth a second look.
for (const kind of ["in-page", "unreachable"]) {
  const h = harness({ ok: false, kind, why: `a ${kind} failure` }, ok);
  const r = await h.open("/dashboard");
  if (!r.ok || h.asked.length !== 2) bad(`a ${kind} failure was not asked again`);
}

/**
 * The failures that cannot answer differently are not asked again.
 *
 * Each is named here rather than taken from SETTLED, because a loop over
 * SETTLED proves only that SETTLED says what SETTLED says: drop a kind out of
 * it and every assertion in the loop goes with it. The reason each one is
 * settled is written beside it, since that is the part a later change has to
 * argue with.
 */
for (const [kind, why] of [
  // The jar is empty, and ten seconds will not fill it. This is the one that
  // matters most: on 15 Oct a middleware fault signed the check out halfway
  // through, and every screen after it failed this way. Asking those twice
  // spends the whole budget on an answer that was never going to change, and
  // the screens that come after get failed on one look for it.
  ["no-session", "the check signed itself out, and waiting will not sign it back in"],
  // Who this account is, or what the navigation offers. Both answer the same
  // way all day, and the second one is a design question rather than a fault.
  ["sent", "a redirect to /login, /no-access or the dashboard is about access, not weather"],
  // A loop is the six hops it was given, twice.
  ["loop", "a redirect loop is a loop again ten seconds later"],
]) {
  if (!SETTLED.includes(kind)) bad(`"${kind}" is no longer settled - ${why}`);
  const h = harness({ ok: false, kind, why: `a ${kind} failure` });
  const r = await h.open("/clients");
  if (r.ok) bad(`a ${kind} failure came back open`);
  if (h.asked.length !== 1) bad(`a ${kind} failure was asked ${h.asked.length} times - ${why}`);
  if (h.waited.length) bad(`a ${kind} failure waited ${h.waited[0]}ms for the same answer - ${why}`);
  if (/twice/.test(r.why)) bad(`a ${kind} failure was reported as having been asked twice`);
}
if (SETTLED.length !== 3) {
  bad(`${SETTLED.length} kinds are settled, and three are accounted for here - a new one needs its reason written down beside the others`);
}

// A failure with no kind at all is asked again: a needless second look costs
// ten seconds, and a missed one puts production back over nothing.
{
  const h = harness({ ok: false, why: "something nobody labelled" }, ok);
  const r = await h.open("/clients");
  if (!r.ok || h.asked.length !== 2) bad("an unlabelled failure was not asked again, which is the dangerous way round to be wrong");
  if (!askAgain({ ok: false, why: "no kind" })) bad("askAgain refuses a second look to a failure with no kind");
}
if (askAgain({ ok: true })) bad("askAgain would ask again about a screen that opened");
if (askAgain(null)) bad("askAgain would ask again about nothing at all");

// ── the budget ────────────────────────────────────────────────
// A deploy that breaks everything must still be able to report. Past the cap
// a screen is failed on one answer, and the run says that is what happened.
{
  const h = harness(five00);
  const results = [];
  for (let i = 0; i < BUDGET + 3; i++) results.push(await h.open(`/screen-${i}`));
  if (h.spent() !== BUDGET) bad(`${h.spent()} second looks were spent, and the budget is ${BUDGET}`);
  if (h.waited.length !== BUDGET) bad(`the run waited ${h.waited.length} times, and the budget is ${BUDGET}`);
  if (h.unpaid.length !== 3) bad(`${h.unpaid.length} screens were failed on one answer, and 3 were past the budget`);
  const last = results.at(-1);
  if (!/asked once only/.test(last.why)) bad(`the screen past the budget says "${last.why}", which does not say it was only asked once`);
  const report = h.lines().join("\n");
  if (!report.includes(`/screen-${BUDGET + 2}`)) bad("the retry report does not name the screens it stopped asking twice");
  if (!new RegExp(`${BUDGET} second look`).test(report)) bad("the retry report does not say how much of the budget went");
  // Worst case has to fit the job: the smoke job is cancelled at ten minutes
  // and takes three, and a cancelled job opens no issue and rolls nothing back.
  if ((BUDGET * AFTER_MS) / 1000 > 180) bad(`the budget can add ${(BUDGET * AFTER_MS) / 1000}s to a job that is cancelled at ten minutes`);
}

// ── 2. ten seconds, and nothing can turn it down ──────────────
if (AFTER_MS !== 10_000) bad(`the second look waits ${AFTER_MS}ms, and the rule is ten seconds`);
if (BUDGET < 3) bad(`a budget of ${BUDGET} is not enough second looks to be worth having`);
{
  const src = read("scripts/retry-screen.mjs");
  if (/process\.env/.test(src)) {
    bad("retry-screen.mjs reads the environment, so a variable set in the workflow could turn the rule off without changing a line of it");
  }
  for (const missing of [{ open: async () => ({ ok: true }) }, { wait: async () => {} }, {}]) {
    let threw = false;
    try {
      retrying(missing);
    } catch {
      threw = true;
    }
    if (!threw) bad(`retrying({${Object.keys(missing).join()}}) was accepted, so a caller can wire it up with half the rule`);
  }
}

// ── 3. the deploy check is wired to it ────────────────────────
const smoke = read("scripts/smoke.mjs");

if (!/import \{ retrying \} from "\.\/retry-screen\.mjs"/.test(smoke)) {
  bad("scripts/smoke.mjs does not import the rule");
}

/**
 * The deploy check must not pass its own wait or its own budget.
 *
 * A caller that can shorten the wait is a caller that can turn the rule off,
 * and `retrying` takes both as arguments so a check can drive it without
 * sitting through two minutes. That is for the check and nothing else.
 */
const wiring = smoke.match(/const retry = retrying\(\{[^}]*\}\);/s)?.[0] ?? "";
if (!wiring) bad("scripts/smoke.mjs never calls retrying, so no screen is asked twice");
if (!/open:\s*openOnce/.test(wiring)) bad("the deploy check wraps something other than openOnce");
if (!/wait:/.test(wiring)) bad("the deploy check passes no wait, so the second look is immediate");
if (/after:|budget:/.test(wiring)) bad("the deploy check overrides the wait or the budget, which is how the rule gets turned down to nothing");
if (!/setTimeout/.test(wiring)) bad("the deploy check's wait does not wait");

/** Every screen read goes through the wrapper, and nothing calls openOnce. */
const calls = [...smoke.matchAll(/openOnce\(/g)];
if (calls.length !== 1) {
  bad(`openOnce is called ${calls.length - 1} time(s) directly, and a direct call is a screen read with no second look`);
}
if (!/async function openOnce\(path\)/.test(smoke)) bad("scripts/smoke.mjs has no openOnce to wrap");
if (!/^const open = retry\.open;$/m.test(smoke)) bad("scripts/smoke.mjs does not point `open` at the wrapped opener");

/**
 * Every failure openOnce can return carries a kind.
 *
 * Found by matching braces rather than by reading the sentences, because the
 * sentences are for whoever opens the issue and have been reworded three
 * times. A failure with no kind is still asked again - the safe side - but it
 * is asked again for the wrong reason, and the next kind that wants to be
 * settled will be the one that was never labelled.
 */
{
  const from = smoke.indexOf("async function openOnce(path)");
  const to = smoke.indexOf("\n}\n", from);
  const body = smoke.slice(from, to);
  const kinds = new Set();
  let unlabelled = 0;
  for (const m of body.matchAll(/ok: false/g)) {
    // Back to the brace that opens this object, then forward to its match.
    let start = body.lastIndexOf("{", m.index);
    let depth = 0;
    let end = start;
    for (; end < body.length; end++) {
      if (body[end] === "{") depth += 1;
      else if (body[end] === "}" && --depth === 0) break;
    }
    const object = body.slice(start, end + 1);
    const kind = object.match(/kind: "([a-z-]+)"/)?.[1];
    if (kind) kinds.add(kind);
    else unlabelled += 1;
  }
  if (!kinds.size) bad("no failure in openOnce carries a kind, so the rule cannot tell a 404 from a signed-out session");
  if (unlabelled) bad(`${unlabelled} failure(s) in openOnce carry no kind, so they are asked again by default rather than on purpose`);
  for (const kind of SETTLED) {
    if (!kinds.has(kind)) bad(`retry-screen.mjs settles "${kind}", and openOnce never returns it - a settled kind nothing returns settles nothing`);
  }
  // The failures the rule exists for. Each one must still be asked twice.
  for (const kind of ["status", "in-page", "unreachable"]) {
    if (!kinds.has(kind)) bad(`openOnce no longer returns "${kind}", which is one of the failures the second look is for`);
    if (SETTLED.includes(kind)) bad(`"${kind}" is settled, so the failure the rule was written for is never asked twice`);
  }
}

/**
 * The board asks its question inside the look, not after it.
 *
 * This is the one screen in the run whose fault was an assertion rather than
 * a status, and the shape is easy to lose: read the page, then test the body
 * a few lines down, and the second look is gone again without a word.
 */
{
  const asked = /open\("\/communication\/threads",\s*\(r\)\s*=>/.test(smoke);
  if (!asked) {
    bad("the client threads board does not pass its assertion to the opener, so its table and groups get one look");
  }
  const call = smoke.match(/const threads = await open\([\s\S]{0,600}?\n\}\);/)?.[0] ?? "";
  for (const mark of ['class="board"', "Needs a reply"]) {
    const inCall = call.includes(mark);
    const after = smoke.slice(smoke.indexOf("const threads = await open(") + call.length).includes(mark);
    if (!inCall) bad(`the board's look does not test for ${mark}, which is how it draws nothing and passes`);
    if (after) bad(`${mark} is tested again after the look, where a second look cannot reach it`);
  }
}

/** A flaky screen shows up: in the list, at the end, and before the verdict. */
if (!/flaky /.test(smoke)) bad("the run's list of screens does not mark the ones that only opened on the second look");
if (!/retry\.lines\(\)/.test(smoke)) bad("the run never prints what the second looks found");
{
  const report = smoke.indexOf("retry.lines()");
  const verdict = smoke.indexOf("ALL ${all.length} SCREENS OPENED");
  const counted = smoke.indexOf("const failed = all.filter((r) => !r.ok)");
  if (report < 0 || verdict < 0) bad("the run's verdict or its retry report has moved, and the order of the two is the point");
  else if (report > verdict) bad("the retry report is printed after the verdict, so a failing run never reaches it");
  if (counted < 0) bad("the run no longer counts its failures from `ok`, so a flaky screen may be failing it");
  else if (counted > report) bad("the failures are counted after the retry report, which is not the order the exit code is decided in");
}
/** And the workflow has to carry the tail of the log that holds it. */
{
  const yml = read(".github/workflows/smoke.yml");
  const tail = yml.match(/tail -(\d+) smoke\.log/)?.[1];
  if (!tail) bad("the workflow no longer puts the deploy check's log in the run summary");
  else if (Number(tail) < 40) bad(`the run summary carries ${tail} lines of the log, which may not reach the retry report at the end of it`);
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the second look`);
  process.exit(1);
}
console.log("  ok  a screen that fails is asked once more after ten seconds, and the run says which");
