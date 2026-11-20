/**
 * Never push while a deploy check is running on production.
 *
 *   node scripts/check-push-guard.mjs
 *
 * The rule of 20 November, and the only one of the evening's rules that is
 * about what a person does rather than what a screen says. It is enforced in
 * two places and this asks both:
 *
 *   - .github/workflows/smoke.yml queues the checks on production, so two
 *     never drive the site at once;
 *   - .githooks/pre-push refuses the push that would start the second one,
 *     through `wait-for-deploy.mjs --before-push` and scripts/push-guard.mjs.
 *
 * Three things it deliberately does not do by reading the files for words:
 *
 * The concurrency group is *evaluated*, not grepped. A group of
 * `deploy-check-${{ github.sha }}` contains every word a grep would look for
 * and queues nothing at all, because every commit gets a group of its own -
 * the fault wearing the fix's clothes, which is the failure mode CLAUDE.md
 * names first. So the expression is parsed and run against two production
 * events, and the rule asked of the answer: do these two land in the same
 * group.
 *
 * The guard's answers are asked of fixtures, including the one that matters
 * most - GitHub could not be read - because that is the case the old code got
 * wrong in the other direction: a rate limit reported "checks not started",
 * and a push would have gone out on it.
 *
 * And the refusal is run for real, as a child process with GitHub's answer
 * stubbed, because what stops a push is an exit code. A guard that prints the
 * right sentence and exits 0 is not a guard.
 */
import { readFileSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { pushVerdict, refsPushed, ANYWAY } from "./push-guard.mjs";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];
const read = (p) => readFileSync(path.join(root, p), "utf8").replace(/\r\n/g, "\n");

// ── 1. what the guard answers ────────────────────────────────
const MAIN = "refs/heads/main abc1234000000000000000000000000000000000 refs/heads/main def5678000000000000000000000000000000000";
const PORTAL = "refs/heads/portal abc1234000000000000000000000000000000000 refs/heads/portal 0000000000000000000000000000000000000000";
const DELETE_MAIN =
  "(delete) 0000000000000000000000000000000000000000 refs/heads/main def5678000000000000000000000000000000000";

const run = (over) => ({
  head_sha: "1234567890abcdef1234567890abcdef12345678",
  head_branch: "main",
  status: "completed",
  conclusion: "success",
  ...over,
});

const cases = [
  {
    say: "nothing is running, so the push goes out",
    ask: { refs: refsPushed(MAIN), runs: [run({}), run({ conclusion: "failure" })] },
    want: true,
  },
  {
    say: "a check is walking the screens right now",
    ask: { refs: refsPushed(MAIN), runs: [run({ status: "in_progress", conclusion: null })] },
    want: false,
  },
  {
    say: "a check is queued and has not been given a runner yet",
    ask: { refs: refsPushed(MAIN), runs: [run({ status: "queued", conclusion: null })] },
    want: false,
  },
  {
    say: "a check is waiting on an approval gate",
    ask: { refs: refsPushed(MAIN), runs: [run({ status: "waiting", conclusion: null })] },
    want: false,
  },
  {
    say: "the newest run finished and an older one is somehow still open",
    ask: {
      refs: refsPushed(MAIN),
      runs: [run({}), run({ status: "in_progress", conclusion: null })],
    },
    want: false,
  },
  {
    say: "the only run in flight is a preview's, on another branch",
    ask: {
      refs: refsPushed(MAIN),
      runs: [run({ status: "in_progress", conclusion: null, head_branch: "portal" })],
    },
    want: true,
  },
  {
    say: "the push is to the portal branch, which deploys nothing",
    ask: { refs: refsPushed(PORTAL), runs: [run({ status: "in_progress", conclusion: null })] },
    want: true,
  },
  {
    say: "main is being deleted, which deploys nothing",
    ask: { refs: refsPushed(DELETE_MAIN), runs: [run({ status: "in_progress", conclusion: null })] },
    want: true,
  },
  {
    say: "run by hand with no refs at all: the question is about main",
    ask: { refs: [], runs: [run({ status: "in_progress", conclusion: null })] },
    want: false,
  },
  {
    say: "GitHub could not be read, which is not the same as reading no runs",
    ask: { refs: refsPushed(MAIN), runs: [], unknown: "GitHub is rate-limiting this machine" },
    want: false,
  },
  {
    say: "production is broken and the owner says push anyway",
    ask: {
      refs: refsPushed(MAIN),
      runs: [run({ status: "in_progress", conclusion: null })],
      anyway: true,
    },
    want: true,
  },
  {
    say: "push anyway, and GitHub unreadable on top of it",
    ask: { refs: refsPushed(MAIN), runs: [], unknown: "GitHub could not be reached", anyway: true },
    want: true,
  },
];

for (const c of cases) {
  const said = pushVerdict(c.ask);
  if (said.push !== c.want) {
    failures.push(
      `push-guard: ${c.say} - wanted ${c.want ? "the push" : "a refusal"}, got ${
        said.push ? "the push" : "a refusal"
      } (${said.why}).`,
    );
  }
}

// Not knowing has to read as not knowing. Both refusals stop the push, and a
// person who cannot tell them apart goes looking for a run that is not there.
const notKnown = pushVerdict({ refs: refsPushed(MAIN), runs: [], unknown: "GitHub is rate-limiting this machine" });
const running = pushVerdict({ refs: refsPushed(MAIN), runs: [run({ status: "in_progress", conclusion: null })] });
if (notKnown.kind === running.kind || notKnown.why === running.why) {
  failures.push("push-guard: a check that could not be read says the same thing as a check that is running.");
}
// Every refusal names the way past it, or it is a rule that gets turned off
// wholesale the first night production is broken.
for (const said of [notKnown, running]) {
  if (!said.why.includes(ANYWAY)) {
    failures.push(`push-guard: a refusal does not say how to push anyway: ${said.why}`);
  }
}

// ── 2. the workflow queues its checks ────────────────────────
const WORKFLOW = ".github/workflows/smoke.yml";
const yml = read(WORKFLOW);

const block = yml.match(/\nconcurrency:\n((?:[ \t]+\S.*\n|\s*\n)+)/)?.[1] ?? "";
if (!block.trim()) {
  failures.push(
    `${WORKFLOW}: there is no concurrency block, so two deploy checks can drive production at the same time.`,
  );
}

const cancels = block.match(/cancel-in-progress:\s*(\S+)/)?.[1];
if (cancels !== "false") {
  failures.push(
    `${WORKFLOW}: cancel-in-progress is ${cancels ?? "not set"} - the run in flight has to finish and say so, ` +
      `or the verdict it has half-collected is thrown away.`,
  );
}

/**
 * Enough of GitHub's expression language to answer the question.
 *
 * `&&` and `||` return an operand rather than a boolean, as they do in
 * JavaScript, which is what makes the `a && b || c` shape work at all.
 */
function evaluate(src, context) {
  const tokens = [];
  const pattern = /\s*('(?:[^']|'')*'|[A-Za-z_][\w.-]*|\d+|&&|\|\||==|!=|[(),])/g;
  let at = 0;
  for (let m; (m = pattern.exec(src)); ) {
    if (m.index !== at) break;
    tokens.push(m[1]);
    at = pattern.lastIndex;
  }
  if (src.slice(at).trim()) throw new Error(`cannot read ${JSON.stringify(src.slice(at).trim())}`);

  let i = 0;
  const peek = () => tokens[i];
  const take = () => tokens[i++];
  const falsy = (v) => v === false || v === "" || v === 0 || v === null || v === undefined;

  const primary = () => {
    const t = take();
    if (t === undefined) throw new Error("the expression ends early");
    if (t === "(") {
      const v = or();
      if (take() !== ")") throw new Error("a bracket is not closed");
      return v;
    }
    if (t.startsWith("'")) return t.slice(1, -1).replace(/''/g, "'");
    if (/^\d+$/.test(t)) return Number(t);
    if (t === "true") return true;
    if (t === "false") return false;
    if (t === "null") return null;
    if (t === "format") {
      if (take() !== "(") throw new Error("format without brackets");
      const args = [];
      while (peek() !== ")") {
        args.push(or());
        if (peek() === ",") take();
      }
      take();
      const [shape, ...rest] = args;
      return String(shape).replace(/\{(\d+)\}/g, (_, n) => String(rest[Number(n)] ?? ""));
    }
    return t.split(".").reduce((o, key) => (o == null ? undefined : o[key]), context);
  };
  const compare = () => {
    let left = primary();
    while (peek() === "==" || peek() === "!=") {
      const op = take();
      const right = primary();
      left = op === "==" ? left === right : left !== right;
    }
    return left;
  };
  const and = () => {
    let left = compare();
    while (peek() === "&&") {
      take();
      const right = compare();
      left = falsy(left) ? left : right;
    }
    return left;
  };
  const or = () => {
    let left = and();
    while (peek() === "||") {
      take();
      const right = and();
      left = falsy(left) ? right : left;
    }
    return left;
  };
  const value = or();
  if (i !== tokens.length) throw new Error(`${tokens.length - i} tokens left over`);
  return value;
}

// The group, as one line, whatever the block's folding.
const groupSrc = (block.match(/group:\s*(?:[>|][-+]?\s*)?\n?((?:.|\n)*?)(?=\n\s*[a-z-]+:|$)/)?.[1] ?? "")
  .split("\n")
  .map((l) => l.trim())
  .filter(Boolean)
  .join(" ");
const inner = groupSrc.match(/^\$\{\{([\s\S]*)\}\}$/)?.[1];

const deployment = (environment, run_id, sha) => ({
  github: { event_name: "deployment_status", event: { deployment: { environment } }, run_id, sha },
});
const byHand = (run_id) => ({
  github: { event_name: "workflow_dispatch", event: {}, run_id, sha: `sha-${run_id}` },
});

if (!inner) {
  if (block.trim()) failures.push(`${WORKFLOW}: the concurrency group is not an expression: ${groupSrc || "(nothing)"}`);
} else {
  let groupOf = null;
  try {
    groupOf = (context) => String(evaluate(inner.trim(), context) ?? "");
  } catch (e) {
    failures.push(`${WORKFLOW}: the concurrency group cannot be read - ${e.message}`);
  }
  if (groupOf) {
    const asks = [
      {
        say: "two production deploys queue behind each other",
        a: deployment("Production", "11", "aaaaaaa"),
        b: deployment("Production", "22", "bbbbbbb"),
        same: true,
      },
      {
        say: "a hand-run check does not sit in production's queue, where it would cancel a pending verdict",
        a: deployment("Production", "11", "aaaaaaa"),
        b: byHand("33"),
        same: false,
      },
      {
        say: "two hand-run checks do not queue behind each other",
        a: byHand("33"),
        b: byHand("44"),
        same: false,
      },
      {
        say: "a preview's run does not sit in production's queue",
        a: deployment("Production", "11", "aaaaaaa"),
        b: deployment("Preview", "55", "ccccccc"),
        same: false,
      },
      {
        say: "two previews do not queue behind each other",
        a: deployment("Preview", "55", "ccccccc"),
        b: deployment("Preview", "66", "ddddddd"),
        same: false,
      },
    ];
    for (const ask of asks) {
      let a;
      let b;
      try {
        a = groupOf(ask.a);
        b = groupOf(ask.b);
      } catch (e) {
        failures.push(`${WORKFLOW}: the concurrency group threw on ${ask.say} - ${e.message}`);
        continue;
      }
      if (!a || !b) {
        failures.push(`${WORKFLOW}: the concurrency group comes out empty for ${ask.say}.`);
      } else if ((a === b) !== ask.same) {
        failures.push(
          `${WORKFLOW}: ${ask.say} - wanted ${ask.same ? "one group" : "two groups"}, got ${
            a === b ? `both as ${a}` : `${a} and ${b}`
          }.`,
        );
      }
    }
  }
}

// ── 3. the hook is there, wired, and really refuses ──────────
const HOOK = ".githooks/pre-push";
let hook = "";
try {
  hook = read(HOOK);
} catch {
  failures.push(`${HOOK} is missing, so nothing asks before a push.`);
}
if (hook && !hook.includes("--before-push")) {
  failures.push(`${HOOK} does not ask wait-for-deploy whether the push may go out.`);
}
if (hook && !/\bexec node\b/.test(hook)) {
  failures.push(`${HOOK} does not hand stdin to the guard, so it cannot tell which branch is being pushed.`);
}

const pkg = JSON.parse(read("package.json"));
const prepare = pkg.scripts?.prepare ?? "";
if (!/core\.hooksPath/.test(prepare) || !prepare.includes(".githooks")) {
  failures.push(
    "package.json has no prepare script pointing git at .githooks, so the hook would live on one machine and nowhere else.",
  );
}

// And the exit code, which is the only part of this a push can feel.
const stub = path.join(tmpdir(), `zion-push-guard-stub-${process.pid}.mjs`);
writeFileSync(
  stub,
  [
    "const said = JSON.parse(process.env.ZION_STUB_RUNS ?? '[]');",
    "globalThis.fetch = async () => {",
    "  if (said === 'rate-limit') return new Response('{}', { status: 403 });",
    "  if (said === 'throw') throw new Error('no network in this fixture');",
    "  return new Response(JSON.stringify({ workflow_runs: said }), { status: 200 });",
    "};",
  ].join("\n"),
);

const ask = (runs, stdin) =>
  spawnSync(
    process.execPath,
    ["--import", pathToFileURL(stub).href, path.join("scripts", "wait-for-deploy.mjs"), "--before-push"],
    {
      cwd: root,
      input: stdin,
      encoding: "utf8",
      env: { ...process.env, ZION_STUB_RUNS: JSON.stringify(runs), ZION_PUSH_ANYWAY: "" },
      timeout: 60000,
    },
  );

const ends = [
  {
    say: "a check in flight stops the push",
    runs: [run({ status: "in_progress", conclusion: null })],
    stdin: MAIN,
    code: 1,
    says: "still in progress",
  },
  {
    say: "a finished check lets it through",
    runs: [run({})],
    stdin: MAIN,
    code: 0,
  },
  {
    say: "GitHub unreadable stops the push and says which of the two it is",
    runs: "rate-limit",
    stdin: MAIN,
    code: 1,
    says: "is not known",
  },
  {
    say: "a push to the portal branch goes out without asking GitHub anything",
    runs: "throw",
    stdin: PORTAL,
    code: 0,
  },
];
for (const end of ends) {
  const said = ask(end.runs, end.stdin);
  const out = `${said.stdout ?? ""}${said.stderr ?? ""}`.trim();
  if (said.status !== end.code) {
    failures.push(
      `wait-for-deploy --before-push: ${end.say} - wanted exit ${end.code}, got ${said.status}: ${out.slice(0, 200)}`,
    );
  } else if (end.says && !out.includes(end.says)) {
    failures.push(`wait-for-deploy --before-push: ${end.say} - the answer does not say "${end.says}": ${out}`);
  }
}

if (failures.length) {
  console.error("check-push-guard FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(
  `check-push-guard ok - ${cases.length} guard fixtures answered, the checks on production queue and are never cancelled, ` +
    `and the hook really exits 1 while one is in flight`,
);
