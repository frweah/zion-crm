/**
 * The one check nobody is watching when it runs.
 *
 * The deploy check puts production back when a screen is broken, and it runs
 * in a place where nobody reads the output: in a runner, after a deploy,
 * usually at night. Two things about it went wrong on 17 November, both of
 * them silently:
 *
 *   it rolled back on *any* failure in the job, not on a broken screen, so a
 *     runner that could not install a browser moved production off a
 *     deployment nothing had found a fault in - and said nothing, because the
 *     issue-opening step has always been gated on the screens step itself;
 *   it rolled back to "the newest ready deployment that is not the current
 *     one", which is the deployment *before* the one under test only while
 *     production is still serving the one under test. It was not, so the
 *     rollback went backwards onto the commit the check had just failed.
 *
 * So this asks both, before every build:
 *
 *   - `scripts/rollback-target.mjs` against fixtures, including that night's,
 *     and including the ones where the only right answer is to refuse;
 *   - the workflow's own gate, evaluated rather than grepped: under a broken
 *     screen it must roll back, and under a runner that fell over it must not,
 *     and in both cases somebody must be told.
 *
 * Evaluated rather than grepped matters. A check that reads the `if:` line and
 * looks for the words "steps.screens" would pass a gate with the condition
 * inverted, which is the fault wearing the fix's clothes.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { rollbackTarget } from "./rollback-target.mjs";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];
const WORKFLOW = ".github/workflows/smoke.yml";
const yml = readFileSync(path.join(root, WORKFLOW), "utf8").replace(/\r\n/g, "\n");

// ── 1. which deployment it goes back to ──────────────────────
// A deployment as Vercel lists it, newest first, with only the fields the
// answer turns on.
const dpl = (uid, sha) => ({ uid, meta: { githubCommitSha: sha } });
const A = dpl("dpl_a", "aaaaaaa1111111111111111111111111111111aa");
const B = dpl("dpl_b", "bbbbbbb1111111111111111111111111111111bb");
const C = dpl("dpl_c", "ccccccc1111111111111111111111111111111cc");
const Bagain = dpl("dpl_b2", B.meta.githubCommitSha);

const cases = [
  {
    say: "the ordinary case: production is on the commit under test",
    ask: { deployments: [B, A], production: "dpl_b", sha: B.meta.githubCommitSha },
    want: "dpl_a",
  },
  {
    say: "17 November: production has already moved on to a later deploy",
    ask: { deployments: [C, B, A], production: "dpl_c", sha: B.meta.githubCommitSha },
    want: null,
  },
  {
    say: "the commit under test is not in the window at all",
    ask: { deployments: [C, A], production: "dpl_c", sha: B.meta.githubCommitSha },
    want: null,
  },
  {
    say: "there is nothing older to go back to",
    ask: { deployments: [B], production: "dpl_b", sha: B.meta.githubCommitSha },
    want: null,
  },
  {
    say: "the same commit was deployed twice, so the one before it is not it",
    ask: { deployments: [Bagain, B, A], production: "dpl_b2", sha: B.meta.githubCommitSha },
    want: "dpl_a",
  },
  {
    say: "a deployment with no commit sha cannot be checked afterwards",
    ask: { deployments: [B, dpl("dpl_cli", ""), A], production: "dpl_b", sha: B.meta.githubCommitSha },
    want: "dpl_a",
  },
  {
    say: "Vercel answered with nothing",
    ask: { deployments: [], production: "dpl_b", sha: B.meta.githubCommitSha },
    want: null,
  },
];

for (const c of cases) {
  const said = rollbackTarget(c.ask);
  if ((said.target ?? null) !== c.want) {
    failures.push(
      `rollback-target: ${c.say} — wanted ${c.want ?? "a refusal"}, got ${said.target ?? "a refusal"} (${said.why}).`,
    );
  }
  // Every answer says why, because the sentence is what goes in the issue.
  if (!said.why || !/\.$/.test(said.why)) {
    failures.push(`rollback-target: ${c.say} — the answer does not say why in a sentence.`);
  }
}

// ── 2. the workflow's gate, evaluated ────────────────────────
/**
 * Enough of GitHub's expression language to answer this question, and no more.
 *
 * It throws on anything it has not been taught, so a future `if:` written in a
 * form this cannot read fails the build instead of quietly evaluating to
 * something. A check that cannot read the condition must not report that the
 * condition is right.
 */
function evaluate(expr, ctx) {
  return expr
    .split("&&")
    .map((t) => t.trim())
    .every((term) => {
      if (term === "failure()") return ctx.failed;
      if (term === "success()") return !ctx.failed;
      if (term === "always()") return true;
      let m = /^steps\.([\w-]+)\.outcome (==|!=) '([\w-]+)'$/.exec(term);
      if (m) {
        const got = ctx.steps[m[1]] ?? "skipped";
        return m[2] === "==" ? got === m[3] : got !== m[3];
      }
      m = /^github\.event_name (==|!=) '([\w-]+)'$/.exec(term);
      if (m) return m[1] === "==" ? ctx.event === m[2] : ctx.event !== m[2];
      throw new Error(`${WORKFLOW}: this check cannot read the condition "${term}".`);
    });
}

/** One step's `if:`, by the step's name, within one job. */
function stepIf(job, name) {
  const jobs = yml.indexOf("\njobs:\n");
  const start = yml.indexOf(`\n  ${job}:\n`, jobs);
  if (start === -1) throw new Error(`${WORKFLOW}: there is no ${job} job.`);
  const next = yml.slice(start + 1).search(/\n {2}\w[\w-]*:\n/);
  const body = next === -1 ? yml.slice(start) : yml.slice(start, start + 1 + next);
  const at = body.indexOf(`- name: ${name}\n`);
  if (at === -1) throw new Error(`${WORKFLOW}: the ${job} job has no step named "${name}".`);
  const after = body.slice(at);
  const until = after.slice(1).search(/\n {6}- /);
  const step = until === -1 ? after : after.slice(0, until + 1);
  const found = /\n\s*if: (.+)\n/.exec(step);
  if (!found) throw new Error(`${WORKFLOW}: the step "${name}" has no if: at all, so it runs whatever happens.`);
  return found[1].trim();
}

try {
  const rollback = stepIf("smoke", "Put production back");
  const told = stepIf("smoke", "Say so");

  // A broken screen, a runner that fell over before the screens step, a later
  // step that failed on its own, a hand-run check, and a clean run.
  const worlds = [
    { say: "a screen threw", ctx: { event: "deployment_status", failed: true, steps: { screens: "failure" } }, roll: true },
    { say: "the runner fell over before any screen was opened", ctx: { event: "deployment_status", failed: true, steps: {} }, roll: false },
    { say: "the screens passed and a later step failed", ctx: { event: "deployment_status", failed: true, steps: { screens: "success" } }, roll: false },
    { say: "a hand-run check found a broken screen", ctx: { event: "workflow_dispatch", failed: true, steps: { screens: "failure" } }, roll: false },
    { say: "everything passed", ctx: { event: "deployment_status", failed: false, steps: { screens: "success" } }, roll: false },
  ];

  for (const w of worlds) {
    if (evaluate(rollback, w.ctx) !== w.roll) {
      failures.push(
        `${WORKFLOW}: when ${w.say}, production ${w.roll ? "must be put back and would not be" : "must be left alone and would be rolled back"}.`,
      );
    }
    // And whatever happened, somebody hears about it. The silence is the part
    // that cost two days in September.
    if (w.ctx.failed && !evaluate(told, w.ctx)) {
      failures.push(`${WORKFLOW}: when ${w.say}, nothing opens an issue and the run just goes red.`);
    }
  }
} catch (err) {
  failures.push(err instanceof Error ? err.message : String(err));
}

// ── 3. nothing checked is not the same as nothing wrong ──────
// Owner, 18 Nov 2026: a run that opened no screens shows as skipped with the
// reason, never as a green tick. Which means the decision has to be a job of
// its own that the other two depend on - a step that steps aside leaves its
// job green, and that is exactly what it used to do.
const job = (name) => {
  const start = yml.indexOf(`\n  ${name}:\n`);
  if (start === -1) return "";
  const next = yml.slice(start + 1).search(/\n {2}\w[\w-]*:\n/);
  return next === -1 ? yml.slice(start) : yml.slice(start, start + 1 + next);
};

const live = job("live");
if (!/outputs:\s*\n\s+ready:/.test(live) || !/api\/version/.test(live)) {
  failures.push(`${WORKFLOW}: the live job does not answer whether production is serving this commit.`);
}
for (const name of ["smoke", "idle"]) {
  const body = job(name);
  if (!/\n {4}needs: (live|\[live, \w+\])\n/.test(body)) {
    failures.push(`${WORKFLOW}: the ${name} job does not wait on the live job, so it can run with nothing to check.`);
  }
  if (!/\n {4}if: needs\.live\.outputs\.ready == 'true'\n/.test(body)) {
    failures.push(`${WORKFLOW}: the ${name} job is not gated on the live job's answer, so "nothing to check" would pass as green.`);
  }
}
// The old shape: the secrets and the wait were steps inside these jobs, which
// is how a run that opened nothing came out green.
for (const name of ["smoke", "idle"]) {
  if (/steps\.ready\.outputs\.ready/.test(job(name))) {
    failures.push(`${WORKFLOW}: the ${name} job still steps aside mid-job instead of being skipped.`);
  }
}

if (failures.length) {
  console.error("check-rollback FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(
  `check-rollback ok — ${cases.length} deployment fixtures answered, the gate rolls back for a broken screen ` +
    `and for nothing else, and a run that checks nothing is skipped rather than green`,
);
