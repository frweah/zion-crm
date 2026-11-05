/**
 * Is what I am about to call "deployed" actually live?
 *
 *   node scripts/check-deployed.mjs
 *
 * Asked of the address staff use, not of a deployment record: production is
 * whatever crm.zionvocrehab.com is serving, and `/api/version` says which
 * commit that is.
 *
 * **Why this exists.** `wait-for-deploy.mjs` has been in this repository for a
 * month and answers the same question. It was never run. Eight consecutive
 * production deployments failed - every one of them reported onward as
 * deployed - because a check I had written passed on the machine I ran it on
 * and failed on Vercel, and nobody looked at the build log. CLAUDE.md has said
 * since the beginning that a check nothing runs is a rule that drifts; it
 * turned out to apply to the deploy itself.
 *
 * So this is deliberately the cheapest possible question - one HTTP GET, no
 * token, no waiting - so that there is no reason not to ask it before writing
 * the word "deployed". When it says the live commit is not this one, the
 * honest report is "pushed, not live", with both hashes in it.
 *
 * It is in `check-checks`'s list of checks that cannot run in prebuild, for a
 * reason that is almost funny: prebuild runs *inside* the deployment it would
 * be checking, which has not finished and so is never READY. A build cannot
 * tell you whether it worked.
 *
 * Exits 0 when the live commit is this one, 1 when it is something else, and
 * 2 when it could not find out - which is not the same as "no", and says so.
 */
import { execSync } from "node:child_process";

const SITE = process.env.SMOKE_BASE_URL ?? "https://crm.zionvocrehab.com";

const head = execSync("git rev-parse HEAD", { encoding: "utf8" }).trim();
const short = head.slice(0, 7);

let pushed = null;
try {
  // What the remote has. A commit that is only local was never going to be
  // live, and saying so is more useful than comparing it with production.
  pushed = execSync("git rev-parse origin/main", { encoding: "utf8" }).trim();
} catch {
  pushed = null;
}

let live = null;
let reached = false;
try {
  const res = await fetch(`${SITE}/api/version`, {
    cache: "no-store",
    signal: AbortSignal.timeout(20_000),
  });
  reached = res.ok;
  if (res.ok) {
    const body = await res.json();
    live = typeof body?.commit === "string" ? body.commit : null;
  } else {
    console.error(`  could not ask ${SITE}: HTTP ${res.status}`);
  }
} catch (err) {
  console.error(`  could not reach ${SITE}: ${err instanceof Error ? err.message : err}`);
}

if (!reached || !live) {
  console.error(
    `\n  UNKNOWN  ${SITE} did not say what it is serving.\n` +
      `           That is not the same as "not live". Report it as unknown and look again.`,
  );
  process.exit(2);
}

console.log(`  local HEAD   ${short}`);
if (pushed && pushed !== head) {
  console.log(`  origin/main  ${pushed.slice(0, 7)}`);
}
console.log(`  live         ${live}`);

if (live === short) {
  console.log(`\n  ok  production is serving this commit — "deployed" is true of ${short}`);
  console.log("\n--- DEPLOYED VERIFIED ---");
  process.exit(0);
}

console.error(
  `\n  FAILED  production is serving ${live} and this is ${short}.\n` +
    `          Report this as "pushed, not live", with both hashes.\n` +
    `          To watch it land:  node scripts/wait-for-deploy.mjs ${short}`,
);
process.exit(1);
