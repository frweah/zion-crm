/**
 * Every screen drawn the same way.
 *
 *   node scripts/check-screens.mjs
 *
 * Step 3 of the consolidation (September 2026) gave the CRM one of each: a
 * screen header (app/(app)/page-head.tsx), a record header
 * (app/(app)/record-header.tsx), a table (app/(app)/data-table.tsx), and tabs
 * that only ever move between screens. Nothing stops the next screen being
 * written the old way except this.
 *
 *   A title written by hand. The header is the component, so every screen has
 *   the same serif title, line of context and actions on the right.
 *
 *   A row of tabs that is not the sidebar's group tabs or a record's own tabs.
 *   A filter or a period is .segmented; tabs stacked under tabs is how a
 *   screen stops being findable.
 *
 *   A raw table. A list of records is the one table - sortable, filterable,
 *   with a sentence when it is empty. A table that lays out something other
 *   than a list says so with data-layout="why".
 */
import { readdir, readFile } from "node:fs/promises";
import { NAV_GROUPS, navPath } from "../lib/roles.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const ROOT = new URL("../", import.meta.url);
const APP = new URL("app/(app)/", ROOT);

async function files(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
    if (entry.isDirectory()) out.push(...(await files(url)));
    else if (entry.name.endsWith(".tsx")) out.push(url);
  }
  return out;
}

/**
 * A path relative to the project, worked out from this script's own location.
 *
 * This used to split an absolute path on "/zion-crm/" and take what followed,
 * which only works in a checkout whose directory happens to be named that. In
 * a git worktree, or in the clone a deployment builds from, the split found
 * nothing and fell back to the absolute path - so check-screens' exemptions,
 * which compare against "app/(app)/page-head.tsx", matched nothing and the
 * check reported the very components it exists to exempt. That is the
 * long-standing "the screens check fails inside a worktree" fault, and it is
 * what broke the build the moment these checks were made to gate it.
 */
const PROJECT = new URL("../", import.meta.url).pathname;
const rel = (url) => {
  const p = decodeURIComponent(url.pathname);
  const root = decodeURIComponent(PROJECT);
  return p.startsWith(root) ? p.slice(root.length) : p;
};
const all = await Promise.all((await files(APP)).map(async (url) => ({ path: rel(url), src: await readFile(url, "utf8") })));

// ── one header ───────────────────────────────────────────────
const HEADERS = ["app/(app)/page-head.tsx", "app/(app)/record-header.tsx"];
const handTitles = all.filter((f) => !HEADERS.includes(f.path) && /<h1\s+className="h1"/.test(f.src));
if (handTitles.length) fail(`titles written by hand instead of PageHead or RecordHeader: ${handTitles.map((f) => f.path).join(", ")}`);
else ok("every title comes from PageHead or RecordHeader");

// Every screen draws one of the two - itself, or through a component of its own
// folder that it renders (Tasks draws its header in tasks-view.tsx).
const byPath = new Map(all.map((f) => [f.path, f.src]));
const drawsHeader = (f) => {
  if (/\b(PageHead|RecordHeader)\b/.test(f.src)) return true;
  const dir = f.path.slice(0, f.path.lastIndexOf("/") + 1);
  // A component beside it, or one directory up - which is where a hub page's
  // shared body lives (Design language, §1).
  for (const m of f.src.matchAll(/from\s+"\.(\.?)\/([^"]+)"/g)) {
    const base = m[1] ? dir.slice(0, dir.lastIndexOf("/", dir.length - 2) + 1) : dir;
    const src = byPath.get(`${base}${m[2]}.tsx`);
    if (src && /\b(PageHead|RecordHeader)\b/.test(src)) return true;
  }
  return false;
};
const pages = all.filter((f) => f.path.endsWith("/page.tsx"));
const headless = pages.filter((f) => !drawsHeader(f));
if (headless.length) fail(`screens with no PageHead or RecordHeader: ${headless.map((f) => f.path).join(", ")}`);
else ok(`all ${pages.length} screens draw the shared screen or record header`);

// ── every screen below a hub has the way back ────────────────
//
// The sidebar gets somebody to a hub's screens. What it never did was get them
// off one: a sub-tab or a record page is reached by clicking into it, and the
// only way out was the browser's own button or guessing which sidebar entry
// came closest. Books had this fixed first; the owner asked for the rest.
//
// So: a screen that is not itself a sidebar entry or a hub page must draw the
// back arrow, and the arrow must point at the screen directly above it - the
// nearest screen that exists, which for a record's sub-page is the record
// itself rather than the list two levels up.
//
// Pointing *somewhere* is not enough, and checking only that `back=` appears
// would pass an arrow aimed at the wrong screen - which is the mistake worth
// catching, because it looks right until somebody clicks it.
const route = (path) => {
  const inner = path.slice("app/(app)/".length, -"page.tsx".length);
  const segs = inner
    .split("/")
    .filter((seg) => seg && !seg.startsWith("(") && !seg.startsWith("@") && !seg.startsWith("_"));
  return "/" + segs.join("/");
};

// Where the sidebar can already take somebody: every entry, and every hub.
const hubLevel = new Set(["/"]);
for (const group of NAV_GROUPS) {
  if (group.hub) hubLevel.add(group.hub);
  for (const item of group.items) hubLevel.add(navPath(item.href));
}

/** A route and a written href compared on shape, so [id] and ${id} are one. */
const shape = (s) =>
  s
    .split(/[?#]/)[0]
    .replace(/\[[^\]]+\]/g, "*")
    .replace(/\$\{[^}]*\}/g, "*")
    .replace(/\/+$/, "") || "/";

/**
 * The href a screen's back arrow points at — written on the header, or held in
 * a constant, or on a header the screen draws through a component of its own.
 */
const BACK_HREF = /back=\{\{\s*href:\s*(?:"([^"]*)"|`([^`]*)`)/;
const backHref = (src, seen = new Set()) => {
  const direct = src.match(BACK_HREF);
  if (direct) return direct[1] ?? direct[2];
  const named = src.match(/back=\{([A-Za-z_$][\w$]*)\}/);
  if (named) {
    const held = src.match(
      new RegExp(`const\\s+${named[1]}\\s*=\\s*\\{\\s*href:\\s*(?:"([^"]*)"|\`([^\`]*)\`)`),
    );
    if (held) return held[1] ?? held[2];
  }
  return null;
};

const screens = pages.map((f) => ({ ...f, route: route(f.path) }));
const allRoutes = new Set(screens.map((s) => s.route));
const noWayBack = [];
const wrongWayBack = [];
let below = 0;

for (const screen of screens) {
  if (hubLevel.has(screen.route)) continue;
  below++;

  // The screen directly above: the nearest ancestor that is itself a screen.
  const segs = screen.route.split("/").filter(Boolean);
  let above = null;
  for (let n = segs.length - 1; n >= 1; n--) {
    const candidate = "/" + segs.slice(0, n).join("/");
    if (allRoutes.has(candidate)) {
      above = candidate;
      break;
    }
  }

  // Written on the page, or on a component beside it that draws the header.
  let href = backHref(screen.src);
  if (href === null) {
    const dir = screen.path.slice(0, screen.path.lastIndexOf("/") + 1);
    for (const m of screen.src.matchAll(/from\s+"\.(\.?)\/([^"]+)"/g)) {
      const base = m[1] ? dir.slice(0, dir.lastIndexOf("/", dir.length - 2) + 1) : dir;
      const beside = byPath.get(`${base}${m[2]}.tsx`);
      if (beside) {
        href = backHref(beside);
        if (href !== null) break;
      }
    }
  }

  if (href === null) {
    noWayBack.push(`${screen.route} (should go back to ${above ?? "its hub"})`);
  } else if (above && shape(href) !== shape(above)) {
    wrongWayBack.push(`${screen.route} goes back to ${href} rather than ${above}`);
  }
}

if (noWayBack.length) {
  fail(
    `screens below a hub with no back arrow — give them RecordHeader's back: ${noWayBack.join(", ")}`,
  );
}
if (wrongWayBack.length) {
  fail(`back arrows pointing past the screen above: ${wrongWayBack.join(", ")}`);
}
if (!noWayBack.length && !wrongWayBack.length) {
  ok(`all ${below} screens below a hub go back to the screen directly above`);
}

// ── tabs move between screens, and never stack ──────────────
const TABS_ALLOWED = ["app/(app)/group-tabs.tsx", "app/(app)/clients/[id]/page.tsx"];
const strayTabs = all.filter((f) => !TABS_ALLOWED.includes(f.path) && /className="tabs"/.test(f.src));
if (strayTabs.length) fail(`tab strips that are not the group tabs or a record's own tabs (use .segmented for a choice): ${strayTabs.map((f) => f.path).join(", ")}`);
else ok("tabs appear only as the sidebar group's tabs and the client record's own");

// ── one table ────────────────────────────────────────────────
const rawTables = [];
for (const f of all) {
  if (f.path === "app/(app)/data-table.tsx") continue;
  for (const m of f.src.matchAll(/<table\b[^>]*>/g)) {
    if (!/data-layout="[^"]+"/.test(m[0])) rawTables.push(f.path);
  }
}
if (rawTables.length) fail(`tables that are neither DataTable nor marked data-layout: ${[...new Set(rawTables)].join(", ")}`);
else ok("every list of records is the shared table; the few layout tables say why");

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- SCREENS VERIFIED ---");
