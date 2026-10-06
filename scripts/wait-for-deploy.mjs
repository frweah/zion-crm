/**
 * Wait until production is serving a commit, and report what the deploy
 * checks made of it.
 *
 *   node scripts/wait-for-deploy.mjs <short-sha>
 *
 * Two questions, asked in one place because they are always asked together:
 * is it live (the site's own /api/version), and did the checks pass (the
 * repository's latest workflow run for that commit). The repository is public,
 * so neither needs a token.
 *
 * Exits 0 when the commit is live and its run succeeded, 1 when the run
 * failed, 2 when it never arrived.
 */
const sha = (process.argv[2] ?? "").trim();
if (!sha) {
  console.error("  FAILED  give the short sha to wait for");
  process.exit(2);
}

const SITE = process.env.SMOKE_BASE_URL ?? "https://crm.zionvocrehab.com";
const REPO = process.env.ZION_REPO ?? "frweah/zion-crm";
const DEADLINE = Date.now() + 1000 * 60 * 25;
/**
 * A token if there is one, and sixty requests an hour if there is not.
 *
 * Unauthenticated, GitHub allows sixty an hour for the whole machine, which
 * two watches and a few questions exhaust - and the symptom is this script
 * reporting that a deploy's checks never started when they had passed. With
 * a read-only token in .env.local it is five thousand an hour and the
 * question never comes up.
 */
const TOKEN = process.env.GITHUB_TOKEN ?? process.env.GH_TOKEN ?? null;
const headers = {
  "user-agent": "zion-crm-deploy-watch",
  ...(TOKEN ? { authorization: `Bearer ${TOKEN}` } : {}),
};

/**
 * How often each thing is asked.
 *
 * The site's own /api/version costs nothing, so it is asked every twenty
 * seconds. GitHub, unauthenticated, allows sixty requests an hour for the
 * whole machine - and asking every twenty seconds spends all sixty on one
 * watch, which is why this reported "checks not started" three times on
 * 6 Oct 2026 for deploys whose checks had passed. Once every two minutes
 * costs a dozen a watch and tells us the same thing.
 */
const SITE_EVERY_MS = 20000;
const GITHUB_EVERY_MS = 120000;

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function live() {
  try {
    const res = await fetch(`${SITE}/api/version`, { cache: "no-store" });
    return (await res.json())?.commit ?? null;
  } catch {
    return null;
  }
}

async function run() {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/actions/runs?per_page=6`, { headers });
    // Unauthenticated, GitHub allows sixty requests an hour for the whole
    // machine. Spending them elsewhere used to read here as "checks not
    // started", which on 6 Oct 2026 reported a deploy as failed when its
    // checks had simply never been asked about. Not knowing is its own
    // answer and is said as one.
    if (res.status === 403 || res.status === 429) {
      const reset = Number(res.headers.get("x-ratelimit-reset"));
      return {
        unknown: `GitHub is rate-limiting this machine${
          Number.isFinite(reset) ? ` until ${new Date(reset * 1000).toISOString().slice(11, 19)} UTC` : ""
        }`,
      };
    }
    const body = await res.json();
    // A preview deployment's run is skipped by design; it says nothing about
    // production and should not be reported as the answer.
    return (body.workflow_runs ?? []).find((r) => r.head_sha.startsWith(sha) && r.conclusion !== "skipped") ?? null;
  } catch {
    return null;
  }
}

let serving = null;
let asked = 0;
let r = null;
let lastSaid = "";
while (Date.now() < DEADLINE) {
  serving = await live();
  // Asked only when it is worth asking, and never before the commit is live:
  // there is nothing for the checks to say until the deploy has landed.
  if (serving === sha && Date.now() - asked >= GITHUB_EVERY_MS) {
    r = await run();
    asked = Date.now();
  }
  const where = serving === sha ? "live" : `live=${serving ?? "?"}`;
  const said = r?.unknown ? r.unknown : r ? `checks ${r.status}/${r.conclusion ?? "running"}` : "checks not started";
  // One line per change, rather than the same line every twenty seconds.
  if (`${where} ${said}` !== lastSaid) {
    console.log(`  ${where}  ${said}`);
    lastSaid = `${where} ${said}`;
  }
  // A rate limit is worth saying at the end, not worth giving up over: it
  // lifts within the hour and the watch may outlast it.
  if (serving === sha && r && !r.unknown && r.status === "completed") {
    if (r.conclusion === "success") {
      console.log("");
      console.log(`--- ${sha} IS LIVE AND ITS CHECKS PASSED ---`);
      process.exit(0);
    }
    console.error(`  FAILED  ${sha} is live and its checks ${r.conclusion}: ${r.html_url}`);
    process.exit(1);
  }
  await sleep(SITE_EVERY_MS);
}

if (serving === sha) {
  console.error(
    r?.unknown
      ? `  UNKNOWN  ${sha} is live; ${r.unknown}, so its checks were never read`
      : `  UNKNOWN  ${sha} is live, and no check run for it appeared in time`,
  );
  process.exit(3);
}
console.error(`  FAILED  ${sha} did not go live in time (serving ${serving ?? "unknown"})`);
process.exit(2);
