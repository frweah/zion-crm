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
const DEADLINE = Date.now() + 1000 * 60 * 20;
const headers = { "user-agent": "zion-crm-deploy-watch" };

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
    const body = await res.json();
    // A preview deployment's run is skipped by design; it says nothing about
    // production and should not be reported as the answer.
    return (body.workflow_runs ?? []).find((r) => r.head_sha.startsWith(sha) && r.conclusion !== "skipped") ?? null;
  } catch {
    return null;
  }
}

let serving = null;
while (Date.now() < DEADLINE) {
  serving = await live();
  const r = await run();
  const where = serving === sha ? "live" : `live=${serving ?? "?"}`;
  console.log(`  ${where}  checks ${r ? `${r.status}/${r.conclusion ?? "running"}` : "not started"}`);
  if (serving === sha && r && r.status === "completed") {
    if (r.conclusion === "success") {
      console.log("");
      console.log(`--- ${sha} IS LIVE AND ITS CHECKS PASSED ---`);
      process.exit(0);
    }
    console.error(`  FAILED  ${sha} is live and its checks ${r.conclusion}: ${r.html_url}`);
    process.exit(1);
  }
  await sleep(20000);
}

console.error(`  FAILED  ${sha} did not go live within twenty minutes (serving ${serving ?? "unknown"})`);
process.exit(2);
