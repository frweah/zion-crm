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

const rel = (url) => decodeURIComponent(url.pathname).split("/zion-crm/")[1] ?? url.pathname;
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
  for (const m of f.src.matchAll(/from\s+"\.\/([^"]+)"/g)) {
    const src = byPath.get(`${dir}${m[1]}.tsx`);
    if (src && /\b(PageHead|RecordHeader)\b/.test(src)) return true;
  }
  return false;
};
const pages = all.filter((f) => f.path.endsWith("/page.tsx"));
const headless = pages.filter((f) => !drawsHeader(f));
if (headless.length) fail(`screens with no PageHead or RecordHeader: ${headless.map((f) => f.path).join(", ")}`);
else ok(`all ${pages.length} screens draw the shared screen or record header`);

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
