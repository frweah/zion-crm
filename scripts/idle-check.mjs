/**
 * How long each screen takes to go quiet, in a real browser.
 *
 * The deploy check opens every screen with fetch, which proves the server
 * answered and says nothing about what the browser then does with the answer.
 * On 30 Sept 2026 the owner reported pages that never seemed to finish
 * loading after moving from the dashboard to Clients or Billing - a fetch
 * check cannot see that at all, because the HTML arrived perfectly well.
 *
 * So this walks the app the way a person does: sign in, open the dashboard,
 * then click each screen's own link in the navigation and wait for the
 * network to go quiet. What it measures is the click-to-quiet time, which is
 * the thing being complained about, and it deliberately excludes the first
 * cold load - a serverless function waking up is not what makes a screen feel
 * stuck.
 *
 *   SMOKE_BASE_URL=https://crm.zionvocrehab.com SMOKE_EMAIL=… SMOKE_PASSWORD=… \
 *   node scripts/idle-check.mjs
 *
 * BUDGET_MS is the owner's target (2 s). CEILING_MS is what fails the deploy:
 * a check that fails on a slow morning in a shared runner would be turned off
 * within a fortnight, so anything between the two is reported loudly and
 * passes, and only a screen that is properly stuck stops the deploy.
 */
import { chromium } from "playwright";

const BASE = (process.env.SMOKE_BASE_URL ?? "https://crm.zionvocrehab.com").replace(/\/$/, "");
const EMAIL = process.env.SMOKE_EMAIL;
const PASSWORD = process.env.SMOKE_PASSWORD;
const BUDGET_MS = Number(process.env.IDLE_BUDGET_MS ?? 2000);
const CEILING_MS = Number(process.env.IDLE_CEILING_MS ?? 8000);
const QUIET_MS = 500;

if (!EMAIL || !PASSWORD) {
  console.log("  note  no SMOKE_EMAIL, so no screen was timed");
  process.exit(0);
}

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
const failures = [];
const slow = [];

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

try {
  await page.goto(`${BASE}/login`, { waitUntil: "domcontentloaded" });
  await page.fill('input[type="email"]', EMAIL);
  await page.fill('input[type="password"]', PASSWORD);
  const signIn = page.locator('form button[type="submit"]').first();
  try {
    await Promise.all([page.waitForURL(/\/(dashboard|paperwork)/, { timeout: 30000 }), signIn.click()]);
  } catch {
    // Said plainly, because the alternative is a stack trace about a selector
    // when the real answer is usually "the password in the secret is stale".
    const said = (await page.locator(".alert").first().textContent().catch(() => null))?.trim();
    console.error(`  FAILED  the check account could not sign in${said ? `: ${said}` : ""}`);
    await browser.close();
    process.exit(1);
  }
  await quiet(15000);

  // Every screen this account's navigation offers, reached the way a person
  // reaches it: by clicking the link, not by typing the address.
  const links = await page.$$eval("nav.side a[href]", (as) =>
    [...new Set(as.map((a) => a.getAttribute("href")).filter((h) => h && h.startsWith("/")))],
  );

  // Signed in and no navigation means the walk below does nothing at all, and
  // a check that silently measures nothing is worse than no check.
  if (links.length === 0) {
    console.error("  FAILED  signed in, but the sidebar offered no links to follow");
    await browser.close();
    process.exit(1);
  }

  for (const href of links) {
    // Warm it first, and time the second visit.
    //
    // The first request to a screen after a deploy wakes a serverless
    // function, which is Vercel's cold start rather than the app's behaviour.
    // Timing that fails this check on a slow morning for a reason nobody can
    // act on - Communication failed once at 8s and measures half a second
    // warm (5 Oct 2026) - and a check that cries wolf is one somebody turns
    // off. What the owner asked for is about the app, so the app is timed.
    await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded" });
    await quiet(15000);
    const warm = await page.$(`nav.side a[href="${href}"]`);
    if (!warm) continue;
    await warm.click();
    await quiet(CEILING_MS + 2000);

    await page.goto(`${BASE}/dashboard`, { waitUntil: "domcontentloaded" });
    await quiet(15000);

    const target = await page.$(`nav.side a[href="${href}"]`);
    if (!target) continue;

    const started = Date.now();
    await target.click();
    const settled = await quiet(CEILING_MS + 2000);
    const took = settled === null ? null : Date.now() - started - QUIET_MS;

    if (took === null) {
      failures.push(`${href} never went quiet - still asking for things after ${CEILING_MS + 2000}ms`);
      console.log(`  FAILED  ${href.padEnd(34)} never quiet`);
    } else if (took > CEILING_MS) {
      failures.push(`${href} took ${took}ms to go quiet, and the ceiling is ${CEILING_MS}ms`);
      console.log(`  FAILED  ${href.padEnd(34)} ${took}ms`);
    } else if (took > BUDGET_MS) {
      slow.push(`${href} ${took}ms`);
      console.log(`  slow    ${href.padEnd(34)} ${took}ms (over the ${BUDGET_MS}ms target)`);
    } else {
      console.log(`  ok      ${href.padEnd(34)} ${took}ms`);
    }
  }
} finally {
  await browser.close();
}

console.log("");
if (slow.length) {
  console.log(`::warning title=Screens over the ${BUDGET_MS}ms target::${slow.join(", ")}`);
}
if (failures.length) {
  for (const f of failures) console.error(`  FAILED  ${f}`);
  process.exit(1);
}
console.log(`--- EVERY SCREEN WENT QUIET WITHIN ${CEILING_MS}ms (${BASE}) ---`);
