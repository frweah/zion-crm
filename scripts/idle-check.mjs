/**
 * How long each screen takes to go quiet, in a real browser.
 *
 * The deploy check opens every screen with fetch, which proves the server
 * answered and says nothing about what the browser then does with the answer.
 * On 30 Sept 2026 the owner reported pages that never seemed to finish
 * loading after moving from the dashboard to Clients or Billing - a fetch
 * check cannot see that at all, because the HTML arrived perfectly well.
 *
 * So this walks the app the way a person does: sign in, open a group, click
 * each of its screens, and wait for the network to go quiet. What it measures
 * is the click-to-quiet time, which is the thing being complained about, and
 * it deliberately excludes the first cold load - a serverless function waking
 * up is not what makes a screen feel stuck.
 *
 *   SMOKE_BASE_URL=https://crm.zionvocrehab.com SMOKE_EMAIL=… SMOKE_PASSWORD=… \
 *   SMOKE_BILLING_EMAIL=… SMOKE_BILLING_PASSWORD=…  *   SMOKE_REPORTS_EMAIL=… SMOKE_REPORTS_PASSWORD=… \
 *   node --experimental-strip-types scripts/idle-check.mjs
 *
 * BUDGET_MS is the owner's target (2 s). CEILING_MS is what fails the deploy:
 * a check that fails on a slow morning in a shared runner would be turned off
 * within a fortnight, so anything between the two is reported loudly and
 * passes, and only a screen that is properly stuck stops the deploy.
 */
import { chromium } from "playwright";
import { NAV_GROUPS, reachableFor } from "../lib/roles.ts";

const BASE = (process.env.SMOKE_BASE_URL ?? "https://crm.zionvocrehab.com").replace(/\/$/, "");
const BUDGET_MS = Number(process.env.IDLE_BUDGET_MS ?? 2000);
const CEILING_MS = Number(process.env.IDLE_CEILING_MS ?? 8000);
const QUIET_MS = 500;
// What the middleware may add before a page is even reached. It runs on every
// request, so whatever it costs is paid by everything; on 14 Oct 2026 it
// awaited an auth round trip with no timeout and production answered nothing
// at all for part of an evening. The ceiling is well under Vercel's own limit,
// because by the time it hits that the site is already down.
const MIDDLEWARE_BUDGET_MS = Number(process.env.MIDDLEWARE_BUDGET_MS ?? 400);
const MIDDLEWARE_CEILING_MS = Number(process.env.MIDDLEWARE_CEILING_MS ?? 2500);

/**
 * Who walks it.
 *
 * A second account rather than a grant: a role sees its own screens and
 * nothing else, which is the point of roles, and the same arrangement already
 * carries Billing's screens through the deploy check (SMOKE_BILLING_*).
 *
 * Intake & Reports, not Admin. An Admin check account would reach every
 * screen, and 0295 refuses one: the read-only promise these accounts carry is
 * 310 restrictive policies over tables, and the 56 functions gated on
 * `is_admin()` are not tables, so an Admin one could act as Admin. What
 * Reports buys in screens is nothing - every screen it reaches, Job Search
 * reaches too - so this walks the same twenty a second time, as a different
 * role. Worth something, because a screen can render for one role and break
 * for another; not coverage.
 *
 * The screens nothing times are named at the end of the run, read out of the
 * navigation rather than written down here, so the list cannot go stale while
 * the gap stays.
 */
const WHO = [
  { who: "check account", role: "Job Search", email: process.env.SMOKE_EMAIL, password: process.env.SMOKE_PASSWORD },
  // Billing's account has existed since 0129 and its secrets are already set,
  // and the timing walk was not using it - so Authorizations, the Service log
  // and Books were "timed by nobody" when the only thing missing was a line
  // here. Found by printing the list rather than by reasoning about it.
  {
    who: "Billing",
    role: "Billing",
    email: process.env.SMOKE_BILLING_EMAIL,
    password: process.env.SMOKE_BILLING_PASSWORD,
    secret: "SMOKE_BILLING_",
  },
  {
    who: "Reports",
    role: "Reports",
    email: process.env.SMOKE_REPORTS_EMAIL,
    password: process.env.SMOKE_REPORTS_PASSWORD,
    secret: "SMOKE_REPORTS_",
  },
];

/** The roles actually walking, which is the ones whose secrets are set. */
const WALKING = WHO.filter((w) => w.email && w.password).map((w) => w.role);

if (!WHO[0].email || !WHO[0].password) {
  console.log("  note  no SMOKE_EMAIL, so no screen was timed");
  process.exit(0);
}

/** The first line of an error, which is the part that says what happened. */
const firstLine = (text) => String(text).split("\n")[0].slice(0, 200);

const browser = await chromium.launch();
const failures = [];
const slow = [];
const timedScreens = [];
const notes = [];

/** Whichever account's browser the walk is in. */
let page = null;

/** Resolves when nothing has been requested for QUIET_MS, or gives up. */
async function quiet(limitMs) {
  const started = Date.now();
  let last = Date.now();
  const bump = () => (last = Date.now());
  page.on("request", bump);
  try {
    while (Date.now() - started < limitMs) {
      if (Date.now() - last >= QUIET_MS) return Date.now() - started - QUIET_MS;
      await new Promise((r) => setTimeout(r, 50));
    }
    return null;
  } finally {
    page.off("request", bump);
  }
}

/**
 * Escape out of anything covering the page.
 *
 * Returns true if something was in the way, which is worth knowing: a link
 * that opens a pane is not a screen and its time is not a screen's time.
 */
async function dismissAnyPane() {
  if (!(await page.$(".pane-shade"))) return false;
  await page.keyboard.press("Escape");
  await page.waitForSelector(".pane-shade", { state: "detached", timeout: 2000 }).catch(() => {});
  if (await page.$(".pane-shade")) {
    failures.push("a pane stayed over the page after Escape, so nothing below it can be clicked");
  }
  return true;
}

/**
 * Why a click did not land.
 *
 * Playwright says "Timeout 8000ms exceeded" on the first line and puts the
 * reason - not visible, not stable, something else receiving the pointer -
 * in the retry log below it. This check reported the first line only, which
 * is the one line that does not say anything: /dashboard "could not be
 * clicked" on every deploy from 30 Oct 2026 and the log never said what was
 * over it.
 *
 * So ask the page directly. Whatever is at the middle of the element is
 * either the element or the thing covering it, and its tag and class name is
 * usually the whole answer.
 */
async function inTheWay(handle) {
  try {
    const box = await handle.boundingBox();
    if (!box) return "it has no box on the page, so it is not being shown";
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    return await page.evaluate(
      ([x, y]) => {
        const at = document.elementFromPoint(x, y);
        if (!at) return `nothing is at (${Math.round(x)}, ${Math.round(y)}); it is off screen`;
        const name = (el) =>
          `<${el.tagName.toLowerCase()}${el.className && typeof el.className === "string" ? ` class="${el.className}"` : ""}>`;
        return (
          `${name(at)} is at the point that would be clicked` +
          (at.closest("a") ? "" : ", and it is not the link")
        );
      },
      [x, y],
    );
  } catch {
    return null;
  }
}

/**
 * Click one link in the sidebar and say how long the screen took to settle.
 *
 * Returns false when the click did not land, which is a finding rather than
 * the end of the walk: it used to throw, and for a week every deploy reported
 * one sentence about /dashboard while the other twenty-three screens went
 * untimed - so the check had stopped measuring the thing it exists to measure
 * and nothing said so.
 */
async function press(selector, name, { timed, who }) {
  const target = await page.$(selector);
  if (!target) return false;

  const from = page.url();
  const started = Date.now();
  let clicked = true;
  await target.click({ timeout: CEILING_MS }).catch(async (e) => {
    clicked = false;
    const why = await inTheWay(target);
    failures.push(`${name} could not be clicked as ${who}: ${firstLine(String(e))}${why ? ` - ${why}` : ""}`);
    console.log(`  FAILED  ${name.padEnd(34)} could not be clicked${why ? ` - ${why}` : ""}`);
  });
  if (!clicked) return false;

  // Team is a sidebar link and a pane over the page, with a shade across
  // everything beneath it to stop a click reaching work somebody cannot see.
  // Right for a person, fatal for a walk that then clicks the next link: it
  // was the last link in the sidebar, so the untimed lap ended with the shade
  // up and the timed lap died on its first link. Closed the way a person
  // closes it, and the walk carries on.
  await dismissAnyPane();

  /**
   * Wait for the address to change, and only then for the network.
   *
   * A client navigation does not necessarily ask for anything in the first
   * half-second, so quiet() returned on the silence *before* the navigation:
   * the address had not moved yet, the screen was reported "already open",
   * and the one after it was timed from the wrong starting point. On
   * production that lost eleven screens of twenty-seven and reported them as
   * already open - which is how a walk can look like it is working and be
   * measuring the pause before the work.
   *
   * The address is the honest signal that the press did something. Where it
   * never moves, the link really did point at the screen we were on.
   */
  const moved = await page
    .waitForURL((u) => String(u) !== from, { timeout: CEILING_MS })
    .then(() => true)
    .catch(() => false);

  const settled = moved ? await quiet(CEILING_MS + 2000) : null;
  if (!timed) return true;

  // A link that goes where we already are is not a navigation, and timing it
  // is timing nothing. It happens honestly - a group whose hub is the screen
  // somebody is on - and said plainly rather than counted as a screen.
  if (!moved) {
    console.log(`  --      ${name.padEnd(34)} already open`);
    return true;
  }

  const took = settled === null ? null : Date.now() - started - QUIET_MS;
  timedScreens.push(name);
  if (took === null) {
    failures.push(`${name} never went quiet as ${who} - still asking for things after ${CEILING_MS + 2000}ms`);
    console.log(`  FAILED  ${name.padEnd(34)} never quiet`);
  } else if (took > CEILING_MS) {
    failures.push(`${name} took ${took}ms to go quiet as ${who}, and the ceiling is ${CEILING_MS}ms`);
    console.log(`  FAILED  ${name.padEnd(34)} ${took}ms`);
  } else if (took > BUDGET_MS) {
    slow.push(`${name} ${took}ms (${who})`);
    console.log(`  slow    ${name.padEnd(34)} ${took}ms (over the ${BUDGET_MS}ms target)`);
  } else {
    console.log(`  ok      ${name.padEnd(34)} ${took}ms`);
  }
  return true;
}

/**
 * One lap of the whole navigation: each group, then each screen inside it.
 *
 * Read a group at a time rather than all at once, because the sidebar shows
 * the six groups and only the open group's screens. Reading `nav.side a[href]`
 * once - which is what this did - gives six groups and whichever group
 * happened to be open when the page loaded, so it timed four screens of
 * twenty-odd, and the entries that were no longer in the DOM were skipped in
 * silence while the ones clicked from the screen they point at were reported
 * as "already open". Opening the group first makes the list the real one.
 *
 * Timed only on the second lap. The first request to a screen after a deploy
 * wakes a serverless function, which is Vercel's cold start rather than the
 * app's behaviour - Communication failed once at 8s and measures half a
 * second warm - and a check that cries wolf is one somebody turns off within
 * a fortnight.
 */
async function lap({ timed, who }) {
  // Waited for, not read the moment the network goes quiet. quiet() returns
  // as soon as no request has been made for a moment, and the sidebar is in
  // the DOM a beat after that - so this read the page too early and failed
  // with "the sidebar offered no links", three seconds in, on a deployment
  // that was perfectly healthy (9 Oct 2026; the deploy check opened forty
  // screens on the same commit). The wait makes the assertion real: if the
  // sidebar truly has no groups, it still fails, just not by racing it.
  await page.waitForSelector(".nav-group > a[href]", { timeout: 15000 }).catch(() => {});
  const groups = await page.$$eval(".nav-group > a[href]", (as) =>
    [...new Set(as.map((a) => a.getAttribute("href")).filter((h) => h && h.startsWith("/")))],
  );

  // Signed in and no navigation means the walk does nothing at all, and a
  // check that silently measures nothing is worse than no check.
  if (groups.length === 0) {
    failures.push(`signed in as ${who}, but the sidebar offered no groups to open`);
    console.log(`  FAILED  the sidebar offered no groups to open as ${who}`);
    return;
  }

  for (const group of groups) {
    await press(`.nav-group > a[href="${group}"]`, group, { timed, who });

    // The group is open now, so these are its real screens rather than a
    // list read before anybody pressed anything.
    const screens = await page.$$eval(".nav-sub a[href]", (as) =>
      [...new Set(as.map((a) => a.getAttribute("href")).filter((h) => h && h.startsWith("/")))],
    );
    if (screens.length === 0 && timed) {
      // A group with no screens under it is either a group that lost them or
      // a sidebar that stopped opening. Both are worth a line.
      console.log(`  --      ${group.padEnd(34)} opened no screens beneath it`);
    }
    for (const screen of screens) {
      await press(`.nav-sub a[href="${screen}"]`, screen, { timed, who });
      // Pressing a screen keeps its own group open, but a screen in a hub can
      // move the open group - so the list is re-read if it has changed under
      // us rather than clicking into a group that is no longer showing.
      if (!(await page.$(`.nav-sub a[href="${screen}"]`))) {
        await page.$(`.nav-group > a[href="${group}"]`).then((g) => g?.click({ timeout: CEILING_MS }).catch(() => {}));
        await quiet(CEILING_MS);
      }
    }
  }
}

try {
  for (const { who, email, password, secret } of WHO) {
    if (!email || !password) {
      notes.push(`no secrets for ${who}, so that role walked nothing`);
      console.log(`  note    no ${secret ?? "SMOKE_"}EMAIL, so ${who} walked nothing`);
      continue;
    }

    // A context of its own per account. Two roles sharing one jar is one role
    // signed in twice, and whichever signed in second is the only one walked.
    const context = await browser.newContext({ viewport: { width: 1280, height: 900 } });
    page = await context.newPage();

    console.log("");
    console.log(`  as ${who}`);

    let signedIn = true;
    // The sign-in page itself not being there is a different fault from a
    // stale password, and saying "page.fill timed out" for it sends whoever
    // reads the log looking at the wrong thing.
    try {
      await page.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" });
      await page.fill('input[type="email"]', email, { timeout: 15000 });
      await page.fill('input[type="password"]', password, { timeout: 15000 });
    } catch {
      signedIn = false;
      failures.push(`${BASE}/login did not offer an email and a password to type into`);
      console.error(`  FAILED  ${BASE}/login did not offer an email and a password to type into`);
    }
    const signIn = page.locator('form button[type="submit"]').first();
    if (!signedIn) {
      await context.close();
      continue;
    }
    await Promise.all([page.waitForURL(/\/(dashboard|paperwork|my-day)/, { timeout: 30000 }), signIn.click()]).catch(
      async () => {
        signedIn = false;
        // Said plainly, because the alternative is a stack trace about a
        // selector when the real answer is usually "the password in the
        // secret is stale".
        const said = (await page.locator(".alert").first().textContent().catch(() => null))?.trim();
        failures.push(`${who} could not sign in${said ? `: ${said}` : ""}`);
        console.error(`  FAILED  ${who} could not sign in${said ? `: ${said}` : ""}`);
      },
    );
    if (!signedIn) {
      await context.close();
      continue;
    }

    await quiet(15000);
    await lap({ timed: false, who });
    await lap({ timed: true, who });

    // ── and what the middleware costs ────────────────────────
    //
    // Measured on a path that does nothing else, so what is timed is the gate
    // rather than a page: /api/version is behind the middleware, answers one
    // string, and touches no database. Whatever that takes is close to pure
    // middleware.
    //
    // Timed signed in and signed out, because they are different paths
    // through it: a request with no auth cookie is answered without Supabase
    // being asked at all, and one with a cookie verifies the token. The slow
    // one is the one that matters, and the incident was the second.
    //
    // It is here rather than in the fetch-based deploy check because this is
    // where timing lives, and a number nobody looks at on every deploy is a
    // number that drifts until it is an outage.
    for (const [whose, ctx] of [[`signed in as ${who}`, context]]) {
      const samples = [];
      for (let i = 0; i < 5; i++) {
        const started = Date.now();
        const res = await ctx.request.get(`${BASE}/api/version`, { failOnStatusCode: false });
        const took = Date.now() - started;
        // A 504 here is the incident itself, and a failure whatever it took.
        if (res.status() >= 500) {
          failures.push(`the middleware answered HTTP ${res.status()} for ${whose} on /api/version`);
          break;
        }
        samples.push(took);
      }
      if (!samples.length) continue;

      // The slowest of five, not the average: the complaint is never about
      // the median request.
      const worst = Math.max(...samples);
      const label = `middleware (${whose})`;
      if (worst > MIDDLEWARE_CEILING_MS) {
        failures.push(`${label} took ${worst}ms, over the ${MIDDLEWARE_CEILING_MS}ms ceiling`);
      } else if (worst > MIDDLEWARE_BUDGET_MS) {
        slow.push(`${label} ${worst}ms`);
        console.log(`  slow    ${label.padEnd(34)} ${worst}ms (target ${MIDDLEWARE_BUDGET_MS}ms)`);
      } else {
        console.log(`  ok      ${label.padEnd(34)} ${worst}ms`);
      }
    }

    await context.close();
  }

  // And the gate as a stranger meets it, which is the other path through the
  // middleware and the one the October incident was on.
  {
    const stranger = await browser.newContext();
    const samples = [];
    for (let i = 0; i < 5; i++) {
      const started = Date.now();
      const res = await stranger.request.get(`${BASE}/api/version`, { failOnStatusCode: false });
      if (res.status() >= 500) {
        failures.push(`the middleware answered HTTP ${res.status()} for a stranger on /api/version`);
        break;
      }
      samples.push(Date.now() - started);
    }
    if (samples.length) {
      const worst = Math.max(...samples);
      const label = "middleware (a stranger)";
      if (worst > MIDDLEWARE_CEILING_MS) {
        failures.push(`${label} took ${worst}ms, over the ${MIDDLEWARE_CEILING_MS}ms ceiling`);
      } else if (worst > MIDDLEWARE_BUDGET_MS) {
        slow.push(`${label} ${worst}ms`);
        console.log(`  slow    ${label.padEnd(34)} ${worst}ms (target ${MIDDLEWARE_BUDGET_MS}ms)`);
      } else {
        console.log(`  ok      ${label.padEnd(34)} ${worst}ms`);
      }
    }
    await stranger.close();
  }
} catch (err) {
  // Anything the walk did not expect - a link that moved, a click that never
  // landed - becomes a finding like any other, because a bare stack trace in
  // a log says less than one line saying what it was doing.
  const said = err instanceof Error ? firstLine(err.message) : String(err);
  failures.push(`the walk stopped: ${said}`);
} finally {
  await browser.close();
}

console.log("");
if (slow.length) {
  console.log(`::warning title=Screens over the ${BUDGET_MS}ms target::${slow.join(", ")}`);
}
if (failures.length) {
  for (const f of failures) console.error(`  FAILED  ${f}`);
  // Said as an annotation, not only in the log.
  //
  // On 6 Oct 2026 this check failed on step 7 and the finding was in the job
  // log, which needs a token to read: the deploy knew which screen was stuck
  // and nobody else could. An annotation shows on the commit and in the pull
  // request, so what the check found is readable where the failure is seen.
  console.log(`::error title=Click to quiet::${failures.join(" %0A ")}`);
  process.exit(1);
}

/**
 * The screens no check account can reach, by name.
 *
 * Asked of the navigation rather than listed here. The gap is a consequence of
 * which roles have a check account, and a list written down beside it would be
 * right on the day and wrong by the next regrouping - the exact fault that
 * left `check-quick-add` asserting six kinds when there were nine.
 *
 * It is a warning and not a failure: nothing is broken, and a deploy that
 * failed because an account the owner has chosen not to create does not exist
 * would be a check nobody keeps. What it may not do is go unsaid.
 */
function whatNothingTimes() {
  const label = new Map();
  for (const g of NAV_GROUPS) for (const i of g.items) label.set(i.href, `${g.label} → ${i.label}`);

  const reached = new Set();
  for (const role of WALKING) {
    for (const item of reachableFor({ role, grants: [] })) reached.add(item.href);
  }
  const everything = new Set();
  for (const g of NAV_GROUPS) for (const i of g.items) everything.add(i.href);

  return [...everything].filter((h) => !reached.has(h)).map((h) => label.get(h) ?? h);
}

const untimed = whatNothingTimes();
if (untimed.length) {
  console.log("");
  console.log(`  ${untimed.length} screens are timed by nobody, because no check account holds a role that reaches them:`);
  for (const name of untimed) console.log(`    -   ${name}`);
  notes.push(`${untimed.length} screens timed by nobody: ${untimed.join(", ")}`);
}

// The count, said out loud. "Every screen" was true of four of them for a
// month, and a sentence that does not say how many cannot be caught at it.
const unique = new Set(timedScreens).size;
for (const n of notes) console.log(`::warning title=Some screens are timed by nobody::${n}`);
console.log(
  `--- ${unique} SCREENS WENT QUIET WITHIN ${CEILING_MS}ms, AND THE MIDDLEWARE WITHIN ${MIDDLEWARE_CEILING_MS}ms (${BASE}) ---`,
);
