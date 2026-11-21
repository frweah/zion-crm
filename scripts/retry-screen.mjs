/**
 * A screen that fails is asked once more, ten seconds later. Two failures in
 * a row is a real one.
 *
 * The rule is the owner's, 20 November 2026, and it is here because of what a
 * single failure can be. That evening a run got a 404 on a path four
 * identical requests in the same run had already got 200 for, and the deploy
 * check did exactly what it is built to do: it rolled production back off a
 * commit that nothing was wrong with. Four commits were going out at once
 * that evening and the queue and `scripts/push-guard.mjs` now stop that
 * particular cause - but a cold function, a dropped connection and a database
 * that answered in nine seconds instead of two are all still single failures
 * that mean nothing, and putting production back is the most expensive thing
 * this check can do.
 *
 * What this must not become is a way for a broken screen to pass. Two things
 * hold that:
 *
 *   The second look is a second look, not an easier question. Same path, same
 *   session, same assertions. A screen that is broken fails it again.
 *
 *   A screen that failed once is named in the run output even though the run
 *   is green - in the list, in a line of its own, and in a GitHub warning on
 *   the run page. A flaky screen nobody can see is worse than a red run,
 *   because it is the same screen every week and nobody is counting.
 *
 * Not every failure is worth asking twice, and that is not politeness: an
 * answer that cannot change in ten seconds costs ten seconds and buys
 * nothing, and a run opens more than a hundred screens. A session the check
 * signed itself out of, a redirect to /login, a redirect loop - the second
 * look reads exactly the same. Those are SETTLED below, named by the `kind`
 * the failure carries rather than by its wording, because the wording is a
 * sentence for somebody to read and has been reworded three times.
 */

/**
 * Ten seconds, because the rule says ten seconds.
 *
 * It is also about the right length for the things it is waiting out - a
 * function that was cold, a connection that was dropped, a pool that was
 * full. A second request sent immediately tends to land in the same bad
 * second.
 */
export const AFTER_MS = 10_000;

/**
 * How many second looks one run will pay for.
 *
 * Twelve at ten seconds each is two minutes added to a job that takes three
 * and is cancelled at ten. Without a cap the arithmetic runs the other way: a
 * deploy that breaks everything fails a hundred screens, a hundred second
 * looks is sixteen minutes, and the job does not have sixteen minutes. It
 * would be *cancelled* rather than failed - and a cancelled job opens no
 * issue and rolls nothing back, so the cap is not about patience. It is about
 * the check still being able to report.
 *
 * Past the cap a screen is failed on its first answer and the run says so in
 * as many words, because "it stopped looking twice" has to be visible too.
 */
export const BUDGET = 12;

/**
 * The failures whose answer cannot change in ten seconds.
 *
 * `no-session` is the check's own doing - the jar is empty, and waiting will
 * not fill it. `sent` is a redirect to /login, /no-access or the dashboard:
 * each is a question about who this account is or what the navigation offers,
 * and both answer the same way all day. `loop` is a redirect loop.
 */
export const SETTLED = ["no-session", "sent", "loop"];

/**
 * Whether asking again could answer differently.
 *
 * A failure that carries no kind at all is asked again. That is the safe side
 * of being wrong about it: a needless second look costs ten seconds, and not
 * looking twice at something transient puts production back on the previous
 * deployment over nothing. `check-retry.mjs` asserts the default rather than
 * leaving it to be read off this comment.
 */
export function askAgain(r) {
  if (!r || r.ok) return false;
  return !SETTLED.includes(r.kind);
}

/**
 * Wrap an opener in the rule.
 *
 * Takes the function that opens one screen and returns the one to call
 * instead, plus the record of what the second looks found. The wait is passed
 * in rather than reached for, so a check can drive the real loop without
 * sitting through two minutes of it.
 */
export function retrying({ open, wait, after = AFTER_MS, budget = BUDGET, say = console.log } = {}) {
  if (typeof open !== "function") throw new Error("retrying needs the opener it wraps");
  if (typeof wait !== "function") throw new Error("retrying needs a wait");

  /** Screens that failed once and opened on the second look. */
  const flaky = [];
  /** Screens failed on one answer because the budget was spent. */
  const unpaid = [];
  let spent = 0;

  const said = `${Math.round(after / 1000)}s`;

  async function openTwice(path) {
    const first = await open(path);
    if (first.ok || !askAgain(first)) return first;

    if (spent >= budget) {
      unpaid.push({ path, why: first.why });
      return {
        ...first,
        why: `${first.why} - asked once only: ${budget} screens had already been asked twice in this run`,
      };
    }

    spent += 1;
    say(`  again   ${path} - ${first.why}; asking again in ${said}`);
    await wait(after);
    const second = await open(path);

    if (second.ok) {
      flaky.push({ path, why: first.why });
      say(`  flaky   ${path} - ${first.why} the first time, opened the second`);
      // The body is the second look's, because that is the one that worked;
      // flakyWhy is what the first look said, so the list at the end of the
      // run can show it against the screen rather than only in a warning.
      return { ...second, flakyWhy: first.why };
    }

    return {
      ...second,
      why:
        `${second.why} - twice, ${said} apart` +
        (second.why === first.why ? "" : ` (the first time: ${first.why})`),
    };
  }

  /** The end of the run: what the second looks found, in lines to print. */
  function lines() {
    const out = [];
    if (flaky.length) {
      out.push(`  ${flaky.length} screen(s) failed once and opened ${said} later:`);
      for (const f of flaky) out.push(`    ${f.path} - ${f.why}`);
      out.push(
        `::warning title=${flaky.length} flaky screen(s)::` +
          flaky.map((f) => `${f.path} (${f.why})`).join("; ") +
          `. Each failed once and opened ${said} later, so this run is not failed on it. ` +
          "A screen that does this on deploy after deploy is a fault, not weather.",
      );
    }
    if (unpaid.length) {
      out.push(
        `  ${unpaid.length} screen(s) were failed on one answer, because ${budget} others ` +
          "had already been asked twice in this run:",
      );
      for (const u of unpaid) out.push(`    ${u.path} - ${u.why}`);
    }
    if (spent) out.push(`  ${spent} second look(s) of the ${budget} this run will pay for`);
    return out;
  }

  return { open: openTwice, flaky, unpaid, lines, spent: () => spent };
}
