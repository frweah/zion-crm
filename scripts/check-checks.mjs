/**
 * A check outside prebuild is a check that rots.
 *
 *   node scripts/check-checks.mjs
 *
 * CLAUDE.md has said this since check-quick-add went stale: a rule that is
 * only written down is a rule that drifts, and a check nothing runs is the
 * same thing wearing a check's clothes. It was written about conventions and
 * it turned out to apply to the checks themselves.
 *
 * On 29 October there were 32 check scripts and prebuild ran 21 of them. Six
 * of the eleven it skipped were ordinary logic checks that pass and had simply
 * never been wired in - among them check-classify and check-auth-parse, which
 * cover the document classifier and the authorization reader. Both had been
 * changed that same day by somebody who believed the suite was running.
 *
 * So the roster is asked rather than kept: every `scripts/check-*.mjs` is
 * either in prebuild or named below with the reason it cannot be. There is no
 * third option, and adding a check without wiring it in fails here.
 */
import { readFile, readdir } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);

/**
 * The checks prebuild cannot run, each with what it needs instead.
 *
 * Every one of these is a check that has to be run by hand, which CLAUDE.md
 * already says of the first two. Being on this list is not permission to be
 * forgotten - it is a note of what would have to change for it to join the
 * others, and three of these are one `server-only` import away.
 */
const CANNOT = {
  "check-hours-race.mjs":
    "needs two database connections to race them; run by hand with --env-file=.env.local",
  "check-end-of-day.mjs":
    "needs a real transaction against the database; run by hand with --env-file=.env.local",
  "check-form-templates.mjs":
    "reads the form templates out of the database; run by hand with --env-file=.env.local",
  "check-1099.mjs":
    "imports a server-only module, so it cannot load outside a request — the fix is to split the shape out, as lib/report-shape.ts was split from lib/report-period.ts",
  "check-irs-forms.mjs":
    "imports a server-only module, so it cannot load outside a request — same fix as check-1099",
};

const dir = new URL("../scripts/", import.meta.url);
const scripts = (await readdir(dir)).filter((n) => /^check-.*\.mjs$/.test(n) && n !== "check-checks.mjs");

const pkg = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const prebuild = pkg.scripts?.prebuild ?? "";

if (!prebuild) {
  problems.push("package.json has no prebuild script, so nothing gates the build at all");
}

const run = scripts.filter((n) => prebuild.includes(n));
const skipped = scripts.filter((n) => !prebuild.includes(n));

for (const name of skipped) {
  if (!CANNOT[name]) {
    problems.push(
      `${name} is in neither prebuild nor the list of checks that cannot run there — add it to prebuild, or say here why it cannot be`,
    );
  }
}

// And the other direction: a reason left behind for a check that has since
// been wired in, or deleted, is a reason that will be believed next time.
for (const name of Object.keys(CANNOT)) {
  if (!scripts.includes(name)) {
    problems.push(`${name} is listed as unable to run in prebuild but no longer exists`);
  } else if (prebuild.includes(name)) {
    problems.push(`${name} runs in prebuild and is also listed as unable to, so one of the two is wrong`);
  }
}

// Every check in prebuild has to exist. A typo in the chain is a check that
// silently never runs, which is this whole file's subject.
for (const named of prebuild.match(/scripts\/check-[a-z0-9-]+\.mjs/g) ?? []) {
  const base = named.replace("scripts/", "");
  if (!scripts.includes(base) && base !== "check-checks.mjs") {
    problems.push(`prebuild runs ${named}, which is not there`);
  }
}

// This file is no use unless prebuild runs it too.
if (!prebuild.includes("check-checks.mjs")) {
  problems.push("prebuild does not run check-checks.mjs, so nothing checks that the checks run");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
ok(`all ${run.length} of ${scripts.length} check scripts run in prebuild`);
ok(`${skipped.length} cannot, each with the reason and what it would take`);
console.log("");
console.log("--- CHECKS VERIFIED ---");
