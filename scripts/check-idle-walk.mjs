/**
 * Does the walk still walk?
 *
 *   node scripts/check-idle-walk.mjs
 *
 * idle-check.mjs is the only check that needs a signed-in browser, so it is
 * the one check nobody could try before a deploy - and it spent a month
 * timing four screens of twenty-seven while reporting "every screen went
 * quiet". Twice over: once because it read the sidebar once when the sidebar
 * shows one group at a time, and once because it measured the network going
 * quiet before a client navigation had changed the address, and called the
 * screens it lost "already open".
 *
 * Neither fault made it fail. Both made it quieter.
 *
 * So the walk is walked against a stand-in shell (idle-fixture.mjs) whose
 * shape is the shape that broke it: groups that open one at a time, a pane
 * with a shade over the page, and an address that changes a beat after the
 * click. What this asserts is not a duration - the fixture is local and
 * durations here mean nothing - but that the walk still *finds* the screens.
 *
 * It cannot run in prebuild: it needs a browser, and prebuild runs on Vercel.
 * It runs in the deploy's timing job, before the real walk, so a walk that
 * has stopped finding screens fails there rather than reporting four of them.
 */
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

// `new URL(...).pathname` is "/C:/Users/..." on Windows, which node cannot
// load - the same platform difference that put eight deploys in ERROR while
// passing on the machine they were written on.
const here = (name) => fileURLToPath(new URL(name, import.meta.url));

const PORT = Number(process.env.FIXTURE_PORT ?? 4399);
const BASE = `http://127.0.0.1:${PORT}`;

// What the fixture offers: six groups, and the screens beneath them. Counted
// from the fixture rather than written down twice, so adding a screen there
// cannot quietly lower the bar here.
const problems = [];
const fail = (said) => problems.push(said);
const ok = (said) => console.log(`  ok  ${said}`);

/** Everything the fixture serves, read out of its own list. */
const { readFile } = await import("node:fs/promises");
const source = await readFile(new URL("./idle-fixture.mjs", import.meta.url), "utf8");
const screens = new Set();
for (const m of source.matchAll(/screens:\s*\[([^\]]*)\]/g)) {
  for (const s of m[1].matchAll(/"([^"]+)"/g)) screens.add(s[1]);
}
const groups = new Set([...source.matchAll(/\{ href: "([^"]+)", label:/g)].map((m) => m[1]));

if (screens.size < 6 || groups.size < 4) {
  fail(`the fixture reads as ${groups.size} groups and ${screens.size} screens, which is not a shell worth walking`);
}

// The walk reports a screen once per address it reaches. A group whose hub is
// also its first screen is reached twice and counted once, so the floor is
// every distinct address the fixture offers, less those duplicates.
const reachable = new Set([...screens, ...groups]);
const WANT = reachable.size - [...groups].filter((g) => screens.has(g)).length;

const server = spawn(process.execPath, [here("./idle-fixture.mjs")], {
  env: { ...process.env, FIXTURE_PORT: String(PORT) },
  stdio: ["ignore", "pipe", "pipe"],
});
let serverSaid = "";
server.stdout.on("data", (d) => (serverSaid += d));
server.stderr.on("data", (d) => (serverSaid += d));

/** Wait for the fixture to answer, rather than sleeping and hoping. */
const up = await (async () => {
  for (let i = 0; i < 100; i++) {
    try {
      const res = await fetch(`${BASE}/api/version`, { signal: AbortSignal.timeout(500) });
      if (res.ok) return true;
    } catch {
      /* not yet */
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  return false;
})();

let said = "";
let code = null;
if (!up) {
  fail(`the fixture never answered on ${BASE}: ${serverSaid.trim() || "it said nothing"}`);
} else {
  const walk = spawn(
    process.execPath,
    ["--experimental-strip-types", here("./idle-check.mjs")],
    {
      env: {
        ...process.env,
        SMOKE_BASE_URL: BASE,
        SMOKE_EMAIL: "fixture@example.test",
        SMOKE_PASSWORD: "fixture",
        // The fixture holds each press for the best part of a second on
        // purpose. The ceiling has to be above that or the walk fails on the
        // delay it exists to reproduce.
        IDLE_BUDGET_MS: "4000",
        IDLE_CEILING_MS: "8000",
        // One role against the fixture, which serves the same fourteen
        // screens to anybody. The real walk signs in twice; this is asking
        // whether it finds screens at all.
        SMOKE_BILLING_EMAIL: "",
        SMOKE_BILLING_PASSWORD: "",
      },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  walk.stdout.on("data", (d) => (said += d));
  walk.stderr.on("data", (d) => (said += d));
  code = await new Promise((r) => walk.on("close", r));
}

server.kill();

if (up) {
  // ── it found the screens ──────────────────────────────────
  const counted = Number((said.match(/--- (\d+) SCREENS WENT QUIET/) ?? [])[1] ?? -1);
  if (counted < 0) {
    fail(`the walk did not say how many screens it timed. It said:\n${said.trim().split("\n").slice(-12).join("\n")}`);
  } else if (counted < WANT) {
    fail(
      `the walk timed ${counted} of the fixture's ${WANT} screens. ` +
        "That is the fault this check exists for: it loses screens quietly and still reports a pass.",
    );
  } else {
    ok(`the walk reached all ${WANT} of the fixture's screens`);
  }

  // ── it opened every group ─────────────────────────────────
  const missed = [...groups].filter((g) => !said.includes(g));
  if (missed.length) {
    fail(`the walk never pressed ${missed.join(", ")}, so those groups' screens were never offered to it`);
  } else {
    ok(`all ${groups.size} groups were opened, so each one's screens were read while it was open`);
  }

  // ── the pane did not stop it ──────────────────────────────
  // The fixture puts a shade over the page when Team is pressed, which is
  // what stopped the real walk dead for a week.
  if (/could not be clicked/.test(said)) {
    fail(`something could not be clicked on a fixture with nothing wrong with it:\n${said.match(/.*could not be clicked.*/)[0]}`);
  } else {
    ok("nothing was left covering the page, so every link stayed clickable");
  }

  // ── and a clean walk passes ───────────────────────────────
  if (code !== 0) {
    fail(`the walk exited ${code} against a fixture where every screen answers at once`);
  } else {
    ok("a shell with nothing wrong with it passes, so a failure means something");
  }
}

if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("\n--- THE WALK STILL WALKS ---");
