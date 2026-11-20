/**
 * Whether a push may go out, given what is running on production.
 *
 * The rule, 20 November 2026: never push while a deploy check is running on
 * production — wait for the verdict.
 *
 * It is a rule because of the four commits of that evening. They went out in
 * half an hour, each one starting a deploy check before the one before it had
 * finished, and each deploy swapped production under the browser the previous
 * check was driving. Two of the three runs failed and neither failure was
 * about the code: one lost the sidebar mid-walk, the other got a 404 on a page
 * four identical requests in the same run had just got 200 for. Every job
 * passed on that code; no single run was ever green on it. A verdict that
 * cannot be read is worse than a slow one, because somebody has to go and
 * decide whether to believe it, and that somebody is the owner.
 *
 * Two things enforce it, and they are different things:
 *
 *   - the workflow queues its own runs, so two checks never drive production
 *     at the same time (`concurrency` in .github/workflows/smoke.yml);
 *   - this refuses the push that would have started the second one.
 *
 * The first alone is not enough: queuing stops the runs from overlapping each
 * other, but the *deploy* still lands while the first run is mid-walk, which
 * is the actual swap. The push is the only place where that can still be
 * stopped.
 *
 * It is a module so `scripts/check-push-guard.mjs` can put the old answer
 * back and watch it fail, and a CLI through `wait-for-deploy.mjs --before-push`
 * so `.githooks/pre-push` can ask it on every push.
 */

/**
 * A run that has not reached a verdict yet.
 *
 * GitHub's own names, every one of them: `requested` and `waiting` are an
 * approval gate, `pending` is a queued-but-not-assigned runner. Reading only
 * `in_progress` would let a push through in the seconds before a runner picks
 * the check up, which is the window the four commits actually went out in.
 */
export const IN_FLIGHT = ["queued", "in_progress", "waiting", "requested", "pending"];

/** Production deploys from main, and from nothing else. */
export const DEPLOYS_FROM = "refs/heads/main";

/** How to push anyway, said in full everywhere it is relevant. */
export const ANYWAY = "ZION_PUSH_ANYWAY=1 git push";

/**
 * The refs a push would move, as git writes them to pre-push on stdin:
 * `<local ref> <local sha> <remote ref> <remote sha>`, one per line.
 */
export function refsPushed(stdin) {
  return String(stdin ?? "")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      const [local, localSha, remote, remoteSha] = line.split(/\s+/);
      return { local, localSha, remote, remoteSha };
    });
}

/**
 * Would this push deploy anything?
 *
 * No lines at all means somebody ran this by hand to ask the question, and
 * the question is about main. A line for another branch is the portal branch
 * and the worktrees, which deploy nothing and must not need the network to
 * push — so they are answered before GitHub is asked anything.
 *
 * A deletion (all-zero local sha) deploys nothing either.
 */
export function reachesProduction(refs) {
  if (!refs.length) return true;
  return refs.some((r) => r.remote === DEPLOYS_FROM && !/^0+$/.test(String(r.localSha ?? "")));
}

/** The deploy checks that have not reached a verdict. */
export function inFlight(runs) {
  return (runs ?? []).filter(
    (r) =>
      r &&
      IN_FLIGHT.includes(String(r.status)) &&
      r.conclusion == null &&
      // A preview deployment's check runs against a branch nobody is being
      // asked to wait for.
      String(r.head_branch) === "main",
  );
}

const short = (s) => String(s ?? "").slice(0, 7);

/**
 * The answer.
 *
 * `unknown` is a sentence saying why GitHub could not be read, and it is not
 * the same as reading it and finding nothing: a rate limit used to report
 * "checks not started" from this same file, and the push would go out on it.
 * So not knowing refuses, in its own words, with the way past it named — the
 * whole point of an override is that the loud answer is the safe one.
 */
export function pushVerdict({ refs = [], runs = [], unknown = null, anyway = false } = {}) {
  if (!reachesProduction(refs)) {
    const names = refs.map((r) => r.remote).join(", ");
    return { push: true, kind: "elsewhere", why: `Nothing here deploys: ${names}.` };
  }
  if (anyway) {
    return {
      push: true,
      kind: "overridden",
      why: "ZION_PUSH_ANYWAY is set, so the deploy check was not asked about.",
    };
  }
  if (unknown) {
    return {
      push: false,
      kind: "unknown",
      why: `${unknown}, so whether a deploy check is running on production is not known — read the last run by hand, or ${ANYWAY}.`,
    };
  }
  const running = inFlight(runs);
  if (running.length) {
    const first = running[0];
    return {
      push: false,
      kind: "in-flight",
      why:
        `The deploy check for ${short(first.head_sha)} is still ${String(first.status).replace("_", " ")} — ` +
        `wait for its verdict with node scripts/wait-for-deploy.mjs ${short(first.head_sha)}, or ${ANYWAY}.`,
      run: first,
    };
  }
  return { push: true, kind: "clear", why: "No deploy check is running on production." };
}
