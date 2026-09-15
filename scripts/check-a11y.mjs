/**
 * The client portal, checked for accessibility. It fails the build.
 *
 *   node scripts/check-a11y.mjs      (runs after `next build` in `npm run build`)
 *
 * The portal is for people who may use a screen reader, a switch, only a
 * keyboard, or text made very large. So this is not advice: any failure stops
 * the deployment.
 *
 * It starts the built app with A11Y_FIXTURES=1, which opens app/portal/a11y -
 * every portal screen drawn from made-up people, since the screens past
 * sign-in need a session the build does not have - and checks each screen for:
 *
 *   WCAG 2.2 AA, by axe-core (wcag2a, wcag2aa, wcag21a, wcag21aa, wcag22aa),
 *   at desktop and phone widths. Includes contrast, labels, names, target size.
 *   One h1, one main landmark, a page title, and a skip link as the first stop.
 *   Keyboard: every control reachable with Tab, focus always visible and on
 *   screen, and never leaving an open dialog (2.1.1, 2.4.7, 2.4.11, 2.1.2).
 *   Reflow at 320 px wide with no sideways scrolling (1.4.10).
 *   Page zoom to 200% - a 1280 px screen - with no sideways scrolling (1.4.4).
 *   Text alone made 200%: every piece of text grows, nothing overflows or is
 *   cut off (1.4.4).
 *   Text spacing raised to the 1.4.12 values without anything cut off.
 *
 * And it checks itself: the "broken" fixture must fail, or the check is not
 * looking.
 */
import { spawn, execSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { chromium } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const PORT = Number(process.env.A11Y_PORT ?? 3217);
const BASE = `http://127.0.0.1:${PORT}`;
const TAGS = ["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"];

const PAGES = [
  "/portal/sign-in",
  "/portal/sign-in?ended=idle",
  "/portal/a11y/sign-in-error",
  "/portal/a11y/verify",
  "/portal/a11y/verify-error",
  "/portal/a11y/consent",
  "/portal/a11y/consent-guardian",
  "/portal/a11y/consent-withdrawn",
  "/portal/a11y/home",
  "/portal/a11y/settings",
  "/portal/a11y/settings-texts-on",
  "/portal/a11y/terms",
  "/portal/a11y/idle-warning",
];

const FOCUSABLE =
  'a[href], button:not([disabled]), input:not([disabled]):not([type="hidden"]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]:not([tabindex="-1"])';

// ── the server ─────────────────────────────────────────────
function startServer() {
  const next = fileURLToPath(new URL("../node_modules/next/dist/bin/next", import.meta.url));
  const child = spawn(process.execPath, [next, "start", "-p", String(PORT), "-H", "127.0.0.1"], {
    env: { ...process.env, A11Y_FIXTURES: "1" },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let log = "";
  child.stdout.on("data", (d) => (log += d));
  child.stderr.on("data", (d) => (log += d));
  return { child, log: () => log };
}

async function waitForServer(ms = 90_000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      const res = await fetch(`${BASE}/portal/sign-in`, { redirect: "manual" });
      if (res.status < 500) return;
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`the app did not answer on ${BASE} within ${ms / 1000} s`);
}

async function launchBrowser() {
  try {
    return await chromium.launch();
  } catch (err) {
    if (!/Executable doesn't exist|playwright install/i.test(String(err))) throw err;
    console.log("  Chromium is not installed here; installing it for this check…");
    execSync("npx playwright install chromium", { stdio: "inherit" });
    return chromium.launch();
  }
}

// ── the checks ─────────────────────────────────────────────
async function open(browser, path, options) {
  const context = await browser.newContext(options);
  const page = await context.newPage();
  const res = await page.goto(BASE + path, { waitUntil: "networkidle" });
  return { context, page, status: res?.status() ?? 0 };
}

async function axe(page) {
  const result = await new AxeBuilder({ page }).withTags(TAGS).analyze();
  return result.violations.map(
    (v) => `${v.id}: ${v.help} (${v.nodes.slice(0, 3).map((n) => n.target.join(" ")).join(" | ")})`,
  );
}

async function structure(page) {
  const s = await page.evaluate(() => ({
    h1: document.querySelectorAll("h1").length,
    main: document.querySelectorAll("main").length,
    title: document.title,
  }));
  const out = [];
  if (s.h1 !== 1) out.push(`has ${s.h1} h1 headings, not one`);
  if (s.main !== 1) out.push(`has ${s.main} main landmarks, not one`);
  if (!s.title || /CRM/.test(s.title)) out.push(`the page title ("${s.title}") does not say what the page is`);
  return out;
}

async function keyboard(page) {
  const out = [];
  const expected = await page.evaluate((selector) => {
    const modal = document.querySelector('[aria-modal="true"]');
    const root = modal ?? document;
    const stops = [...root.querySelectorAll(selector)].filter((el) => {
      const cs = getComputedStyle(el);
      const r = el.getBoundingClientRect();
      return cs.visibility !== "hidden" && cs.display !== "none" && r.width > 0 && r.height > 0;
    });
    stops.forEach((el, i) => el.setAttribute("data-a11y-stop", String(i)));
    return { count: stops.length, modal: Boolean(modal) };
  }, FOCUSABLE);

  if (!expected.modal) {
    await page.evaluate(() => (document.activeElement instanceof HTMLElement ? document.activeElement.blur() : null));
    await page.keyboard.press("Tab");
    const firstStop = await page.evaluate(() => document.activeElement?.textContent?.trim() ?? "");
    if (firstStop !== "Skip to main content") out.push(`the first Tab stop is "${firstStop}", not the skip link`);
    await page.keyboard.press("Shift+Tab");
  }

  const reached = new Set();
  let escaped = false;
  for (let i = 0; i < expected.count + 4; i++) {
    await page.keyboard.press("Tab");
    const info = await page.evaluate(() => {
      const el = document.activeElement;
      if (!el || el === document.body) return null;
      const cs = getComputedStyle(el);
      const r = el.getBoundingClientRect();
      const modal = document.querySelector('[aria-modal="true"]');
      return {
        stop: el.getAttribute("data-a11y-stop"),
        name: (el.getAttribute("aria-label") || el.textContent || el.getAttribute("name") || el.tagName).trim().slice(0, 40),
        visible: (cs.outlineStyle !== "none" && parseFloat(cs.outlineWidth) >= 2) || cs.boxShadow !== "none",
        onScreen: r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth,
        inModal: modal ? modal.contains(el) : true,
      };
    });
    if (!info) continue;
    if (!info.inModal) escaped = true;
    if (info.stop !== null) reached.add(info.stop);
    if (!info.visible) out.push(`keyboard focus on "${info.name}" cannot be seen`);
    if (!info.onScreen) out.push(`keyboard focus on "${info.name}" is off the screen`);
  }
  if (reached.size < expected.count) {
    out.push(`${expected.count - reached.size} of ${expected.count} controls cannot be reached with the Tab key`);
  }
  if (escaped) out.push("keyboard focus leaves the open dialog");
  return out;
}

const overflow = (page) =>
  page.evaluate(() => {
    const clipped = [];
    for (const el of document.querySelectorAll(".portal *")) {
      const cs = getComputedStyle(el);
      if (!/(hidden|clip)/.test(`${cs.overflowX} ${cs.overflowY}`)) continue;
      if (!el.textContent?.trim()) continue;
      if (el.scrollWidth > el.clientWidth + 1 || el.scrollHeight > el.clientHeight + 1) {
        clipped.push(el.tagName.toLowerCase() + (el.id ? `#${el.id}` : ""));
      }
    }
    return {
      wide: document.documentElement.scrollWidth > window.innerWidth + 1 ? document.documentElement.scrollWidth : 0,
      clipped: clipped.slice(0, 4),
    };
  });

// Inputs that show text. Not hidden inputs - Next adds three to every form that
// posts to a server action, and a size nobody sees cannot fail anyone - and not
// tick-boxes, which are sized in rem by the portal's own stylesheet.
const TEXT_SAMPLE =
  ".portal h1, .portal h2, .portal p, .portal li, .portal label, .portal button, .portal a, " +
  '.portal input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])';

async function textResize(page) {
  const out = [];
  const before = await page.evaluate((sel) => [...document.querySelectorAll(sel)].map((el) => parseFloat(getComputedStyle(el).fontSize)), TEXT_SAMPLE);
  await page.addStyleTag({ content: "html { font-size: 200% !important; }" });
  const after = await page.evaluate((sel) => [...document.querySelectorAll(sel)].map((el) => ({ size: parseFloat(getComputedStyle(el).fontSize), name: el.tagName.toLowerCase() + ": " + (el.textContent ?? "").trim().slice(0, 30) })), TEXT_SAMPLE);
  const stuck = after.filter((a, i) => before[i] && a.size / before[i] < 1.8).map((a) => a.name);
  if (stuck.length) out.push(`text does not grow when text is made 200%: ${stuck.slice(0, 3).join(" | ")}`);
  const o = await overflow(page);
  if (o.wide) out.push(`with text at 200% the page scrolls sideways (${o.wide} px)`);
  if (o.clipped.length) out.push(`with text at 200% text is cut off in ${o.clipped.join(", ")}`);
  return out;
}

async function textSpacing(page) {
  await page.addStyleTag({
    content:
      ".portal * { line-height: 1.5 !important; letter-spacing: 0.12em !important; word-spacing: 0.16em !important; } .portal p { margin-bottom: 2em !important; }",
  });
  const o = await overflow(page);
  const out = [];
  if (o.wide) out.push(`with wider text spacing the page scrolls sideways (${o.wide} px)`);
  if (o.clipped.length) out.push(`with wider text spacing text is cut off in ${o.clipped.join(", ")}`);
  return out;
}

async function checkPage(browser, path) {
  const problems = [];
  const note = (list, where) => list.forEach((p) => problems.push(`${where}: ${p}`));

  // Desktop: axe, structure, keyboard.
  {
    const { context, page, status } = await open(browser, path, { viewport: { width: 1280, height: 900 } });
    if (status !== 200) {
      await context.close();
      return [`answered ${status}, not 200`];
    }
    note(await axe(page), "desktop");
    note(await structure(page), "structure");
    note(await keyboard(page), "keyboard");
    await context.close();
  }
  // Phone width: axe again - a layout that stacks can break names and order.
  {
    const { context, page } = await open(browser, path, { viewport: { width: 375, height: 812 } });
    note(await axe(page), "phone");
    await context.close();
  }
  // Reflow at 320 px.
  {
    const { context, page } = await open(browser, path, { viewport: { width: 320, height: 640 } });
    const o = await overflow(page);
    if (o.wide) problems.push(`320 px: the page scrolls sideways (${o.wide} px)`);
    if (o.clipped.length) problems.push(`320 px: text is cut off in ${o.clipped.join(", ")}`);
    await context.close();
  }
  // Page zoom 200% on a 1280 px screen.
  {
    const { context, page } = await open(browser, path, { viewport: { width: 640, height: 450 }, deviceScaleFactor: 2 });
    const o = await overflow(page);
    if (o.wide) problems.push(`zoom 200%: the page scrolls sideways (${o.wide} px)`);
    await context.close();
  }
  // Text alone at 200%, then text spacing, each on a fresh page.
  {
    const { context, page } = await open(browser, path, { viewport: { width: 1280, height: 900 } });
    note(await textResize(page), "text 200%");
    await context.close();
  }
  {
    const { context, page } = await open(browser, path, { viewport: { width: 375, height: 812 } });
    note(await textSpacing(page), "text spacing");
    await context.close();
  }
  return [...new Set(problems)];
}

// ── run ────────────────────────────────────────────────────
const server = startServer();
let failed = false;
try {
  await waitForServer();
  const browser = await launchBrowser();
  try {
    // The check must be able to fail.
    const broken = await checkPage(browser, "/portal/a11y/broken");
    const caught = ["label", "color-contrast"].every((rule) => broken.some((p) => p.includes(`${rule}:`)));
    const sawFocus = broken.some((p) => p.includes("cannot be seen"));
    if (!caught || !sawFocus) {
      failed = true;
      console.error(
        "  FAILED  the check did not catch the deliberately broken screen, so it cannot be trusted:\n" +
          broken.map((p) => `          ${p}`).join("\n"),
      );
    } else {
      console.log("  ok  the check catches a broken screen (missing label, low contrast, invisible focus)");
    }

    for (const path of PAGES) {
      const problems = await checkPage(browser, path);
      if (problems.length === 0) {
        console.log(`  ok  ${path}`);
      } else {
        failed = true;
        console.error(`  FAILED  ${path}\n${problems.map((p) => `          ${p}`).join("\n")}`);
      }
    }
  } finally {
    await browser.close();
  }
} catch (err) {
  failed = true;
  console.error(`  FAILED  the accessibility check could not run: ${err instanceof Error ? err.message : err}`);
  console.error(server.log().slice(-2000));
} finally {
  server.child.kill();
}

if (failed) {
  console.error("\nThe client portal is not accessible enough to ship. Fix the screens above; this is not optional.\n");
  process.exit(1);
}
console.log(`\n--- ${PAGES.length} PORTAL SCREENS PASS WCAG 2.2 AA, KEYBOARD, REFLOW, ZOOM AND TEXT SPACING ---`);
