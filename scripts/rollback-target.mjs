/**
 * Which deployment production goes back to when the deploy check finds a
 * broken screen.
 *
 * The question sounds like one line of jq, and it was one line of jq, and the
 * line was wrong: "the newest ready production deployment that is not the
 * current one". That is the right answer only while production is still on the
 * commit the check was about. On the night of 17 November it was not - a later
 * deploy had already taken over - so the rollback stepped *backwards* off a
 * deployment nothing had found a fault in, onto the one under test.
 *
 * So the rule is stated the other way round, in terms of the commit the check
 * actually opened screens on:
 *
 *   - find that commit's own deployment in the list
 *   - refuse unless production is still serving it
 *   - go back to the newest deployment before it that is a different commit
 *
 * and anything it cannot answer, it refuses in a sentence rather than guessing.
 * A rollback that moves production somewhere nobody reasoned about is worse
 * than a broken screen that is still broken: the broken screen is at least
 * known about, and an issue is opened either way.
 *
 * It is a module so that `scripts/check-rollback.mjs` can put the old answer
 * back and watch it fail, and a CLI so that the workflow can pipe Vercel's
 * answer through it:
 *
 *   echo "$list" | node scripts/rollback-target.mjs --production dpl_x --sha <full sha>
 *
 * It prints one line of JSON: {"target","sha","why"} or {"target":null,"why"}.
 */

const short = (s) => String(s ?? "").slice(0, 7);
const shaOf = (d) => String(d?.meta?.githubCommitSha ?? "");

export function rollbackTarget({ deployments, production, sha }) {
  const list = (deployments ?? []).filter((d) => d && d.uid);
  const want = String(sha ?? "");

  if (!want) {
    return { target: null, why: "Nothing said which commit was being checked, so there is nothing to undo." };
  }
  if (list.length === 0) {
    return { target: null, why: "Vercel listed no ready production deployments, so there is nothing to go back to." };
  }

  const mine = list.findIndex((d) => shaOf(d) === want);
  if (mine === -1) {
    return {
      target: null,
      why: `${short(want)} is not among the last ${list.length} ready production deployments, so what it replaced cannot be worked out.`,
    };
  }
  if (production && list[mine].uid !== production) {
    return {
      target: null,
      why: `Production is not on ${short(want)} any more, so rolling back would move staff off a deployment this check never looked at.`,
    };
  }

  /*
   * The newest one before it that is a *different* commit.
   *
   * A different commit because the same commit deployed twice is the same
   * code, and rolling back onto it would report success while leaving the
   * broken screen exactly where it was. And a commit sha at all because the
   * step finishes by asking crm.zionvocrehab.com which commit it is serving -
   * a deployment that carries no sha can never answer that, so a promote onto
   * one would wait eighteen times and then call itself failed.
   */
  const before = list.slice(mine + 1).find((d) => shaOf(d) && shaOf(d) !== want);
  if (!before) {
    return {
      target: null,
      why: `Nothing ready and older than ${short(want)} is in the list, so there is no earlier deployment to put back.`,
    };
  }

  return {
    target: before.uid,
    sha: short(shaOf(before)),
    why: `${short(shaOf(before))} was serving before ${short(want)} went out.`,
  };
}

// ── the CLI ──────────────────────────────────────────────────
// By the name of the script that was run rather than by comparing
// `import.meta.url` with argv[1]: the usual spelling of that comparison is
// wrong on Windows, where one side has three slashes after file: and the other
// has two, and it fails open - the import would sit waiting on a stdin nobody
// was going to write to.
if (process.argv[1]?.replace(/\\/g, "/").endsWith("/rollback-target.mjs")) {
  const arg = (name) => {
    const i = process.argv.indexOf(`--${name}`);
    return i === -1 ? "" : (process.argv[i + 1] ?? "");
  };
  const chunks = [];
  for await (const c of process.stdin) chunks.push(c);
  let said;
  try {
    const body = JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
    said = rollbackTarget({
      deployments: body.deployments,
      production: arg("production"),
      sha: arg("sha"),
    });
  } catch (err) {
    said = {
      target: null,
      why: `Vercel's list of deployments could not be read (${err instanceof Error ? err.message : String(err)}), so production was left where it is.`,
    };
  }
  process.stdout.write(JSON.stringify(said) + "\n");
}
