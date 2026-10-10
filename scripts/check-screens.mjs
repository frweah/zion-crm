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

// ── every screen says how to get out of it ───────────────────
//
// The sidebar gets somebody to a screen. What it never did was get them off
// one, and there are two kinds of screen with two different answers:
//
//   A hub's tab goes back to where the hub opens, which the navigation already
//   knows. One component in the layout draws that arrow for all of them
//   (hub-back.tsx), beside the tab strip and for the same reason - one list,
//   one rule, and a screen added to a hub does not need somebody to remember
//   an arrow for it.
//
//   A screen below a tab - a record, a sub-page - goes back to the screen
//   directly above, which only that screen knows. It draws its own, on
//   RecordHeader.
//
// The only screens with no way out are the hubs' landings: where Work,
// Communication and HR open on a page of cards, and the first screen of Home,
// Billing and Admin, which have no such page.
//
// Checked, rather than assumed: that each screen is covered by one of the two,
// that the layout really draws the hub arrow, that a screen does not draw two,
// and - for the ones that draw their own - that it points at the screen
// directly above. Checking only that `back=` appears somewhere would pass an
// arrow aimed at the wrong screen, which is the mistake that looks right until
// somebody clicks it.
const route = (path) => {
  const inner = path.slice("app/(app)/".length, -"page.tsx".length);
  const segs = inner
    .split("/")
    .filter((seg) => seg && !seg.startsWith("(") && !seg.startsWith("@") && !seg.startsWith("_"));
  return "/" + segs.join("/");
};

// Where each hub opens, and the screens it reaches through its tab strip.
const landings = new Set(["/"]);
const onATabStrip = new Map();
for (const group of NAV_GROUPS) {
  landings.add(navPath(group.hub ?? group.items[0].href));
  for (const item of group.items) onATabStrip.set(navPath(item.href), group);
}

/** A route and a written href compared on shape, so [id] and ${id} are one. */
const shape = (s) =>
  s
    .split(/[?#]/)[0]
    .replace(/\[[^\]]+\]/g, "*")
    .replace(/\$\{[^}]*\}/g, "*")
    .replace(/\/+$/, "") || "/";

/**
 * The href a screen's own back arrow points at — written on the header, held
 * in a constant, or on a header the screen draws through a component of its
 * own folder.
 */
const BACK_HREF = /back=\{\{\s*href:\s*(?:"([^"]*)"|`([^`]*)`)/;
const ownBack = (src) => {
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

// The hub arrow is only real if the layout draws it — and it has to be handed
// the same navigation the tab strip is handed, and work out where it goes with
// lib/roles' hubBack, which is the one definition the deploy check and
// check-nav's cases also read. A second copy of that rule here is how the
// arrow and the tabs would come to disagree about where somebody is.
const layout = byPath.get("app/(app)/layout.tsx") ?? "";
const hubBackSrc = byPath.get("app/(app)/hub-back.tsx") ?? "";
const handedTo = (component) =>
  (layout.match(new RegExp(`<${component}\\s+groups=\\{([A-Za-z_$][\\w$]*)\\}`)) ?? [])[1];
if (!/<HubBack\b/.test(layout)) {
  fail("the layout does not draw HubBack, so no hub tab has a way back");
} else if (!handedTo("HubBack") || handedTo("HubBack") !== handedTo("GroupTabs")) {
  fail("HubBack and GroupTabs are not given the same navigation, so the arrow can disagree with the tabs");
} else if (!/\bhubBack\b/.test(hubBackSrc)) {
  fail(
    "hub-back.tsx does not use lib/roles' hubBack, so the arrow can disagree with the deploy check and check-nav's cases",
  );
} else {
  ok("the hub's way back is drawn once in the layout, by the one rule the checks read");
}

// One definition of the arrow itself, so the two kinds cannot look different.
const BACK_MARKUP = 'className="sub record-back no-print"';
const drawsArrow = all.filter((f) => f.path !== "app/(app)/back-link.tsx" && f.src.includes(BACK_MARKUP));
if (drawsArrow.length) {
  fail(`the back arrow is written out instead of using BackLink: ${drawsArrow.map((f) => f.path).join(", ")}`);
}

const screens = pages.map((f) => ({ ...f, route: route(f.path) }));
const allRoutes = new Set(screens.map((s) => s.route));
const noWayBack = [];
const wrongWayBack = [];
const twoWaysBack = [];
let viaLayout = 0;
let viaHeader = 0;

for (const screen of screens) {
  if (landings.has(screen.route)) continue;

  // Written on the page, or on a component beside it that draws the header.
  let href = ownBack(screen.src);
  if (href === null) {
    const dir = screen.path.slice(0, screen.path.lastIndexOf("/") + 1);
    for (const m of screen.src.matchAll(/from\s+"\.(\.?)\/([^"]+)"/g)) {
      const base = m[1] ? dir.slice(0, dir.lastIndexOf("/", dir.length - 2) + 1) : dir;
      const beside = byPath.get(`${base}${m[2]}.tsx`);
      if (beside) {
        href = ownBack(beside);
        if (href !== null) break;
      }
    }
  }

  if (onATabStrip.has(screen.route)) {
    // The layout draws this one. Its own arrow would be a second one.
    if (href !== null) twoWaysBack.push(`${screen.route} (the layout already draws one)`);
    else viaLayout++;
    continue;
  }

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

  if (href === null) {
    noWayBack.push(`${screen.route} (should go back to ${above ?? "its hub"})`);
  } else if (above && shape(href) !== shape(above)) {
    wrongWayBack.push(`${screen.route} goes back to ${href} rather than ${above}`);
  } else {
    viaHeader++;
  }
}

if (noWayBack.length) {
  fail(`screens with no way back — give them RecordHeader's back: ${noWayBack.join(", ")}`);
}
if (wrongWayBack.length) {
  fail(`back arrows pointing past the screen above: ${wrongWayBack.join(", ")}`);
}
if (twoWaysBack.length) {
  fail(`screens drawing a second back arrow under the layout's: ${twoWaysBack.join(", ")}`);
}
if (!noWayBack.length && !wrongWayBack.length && !twoWaysBack.length) {
  ok(
    `every screen says how to get out of it — ${viaLayout} hub tabs from the layout, ${viaHeader} records and sub-pages from their own header, ${landings.size - 1} hub landings need none`,
  );
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
