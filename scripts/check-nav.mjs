/**
 * The navigation, checked against the routes that actually exist.
 *
 *   node --experimental-strip-types scripts/check-nav.mjs
 *
 * Three ways a grouped sidebar goes wrong, all of them silent:
 *
 *   A link to a screen that is not there. Nothing warns; the person clicking
 *   it gets a 404 and assumes they are not allowed.
 *
 *   A screen with no way to reach it. It keeps working, keeps being
 *   maintained, and nobody opens it — which is how three Phase 8 screens were
 *   listed for Admin and missing for everybody else.
 *
 *   A moved path with no redirect. Every bookmark, every link in an old
 *   email, every note somebody wrote down.
 */
import { readdir, readFile } from "node:fs/promises";
import { NAV_GROUPS, navFor, navPath, reachableFor, AREAS, AREA_LEVELS, ROLE_AREAS } from "../lib/roles.ts";
import { CLIENT_TABS, MOVED_CLIENT_TABS } from "../lib/client-tabs.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const APP = new URL("../app/(app)/", import.meta.url);

/** Every route with a page, as a URL path. */
async function routes(dir = APP, prefix = "") {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      // Route groups in parentheses do not appear in the URL.
      const segment = entry.name.startsWith("(") ? "" : `/${entry.name}`;
      out.push(...(await routes(new URL(`${entry.name}/`, dir), prefix + segment)));
    } else if (entry.name === "page.tsx") {
      out.push(prefix || "/");
    }
  }
  return out;
}

const existing = await routes();
// Detail screens are reached through their list, not from the sidebar.
const stat = new Set(existing.filter((r) => !r.includes("[")));

// ── every link goes somewhere ────────────────────────────────
const linked = [...new Set(NAV_GROUPS.flatMap((g) => g.items.map((i) => navPath(i.href))))];
for (const href of linked) {
  if (!stat.has(href)) fail(`the sidebar links to ${href}, which has no page`);
}
if (!problems.length) ok(`all ${linked.length} navigation links resolve to a real screen`);

// ── every screen is reachable ────────────────────────────────
// Detail screens under a listed one are reachable through it, so a route is
// covered when the navigation points at it or at something above it.
const covered = (route) =>
  linked.some((href) => route === href || route.startsWith(href + "/"));

const orphans = [...stat].filter((r) => !covered(r) && r !== "/");
if (orphans.length) {
  fail(`no navigation reaches: ${orphans.join(", ")}`);
} else {
  ok(`all ${stat.size} screens are reachable from the sidebar`);
}

// ── the roles reach exactly what they reached before ─────────
// Written out as paths rather than counted, because a count is satisfied by
// losing one screen and gaining another. This is the list the regrouping was
// not supposed to change, plus the two screens that did not exist before it.
// The consolidation (Sept 2026) put these on fewer sidebar entries, so the
// paths listed here are the entries; screens under them (/dashboard/needs,
// /billing/import, /billing/warrants, a records request) are reached through
// them. Insights, Referrals included, is Admin's alone (owner, 14 Sept 2026),
// and so is the whole Admin group (19 Sept 2026): the document inbox, the
// agent's status, the monthly export and the rate schedule are under Billing.
const EXPECTED = {
  Admin: [
    "/admin/documents", "/admin/people", "/admin/system",
    "/billing", "/billing/documents", "/billing/export", "/billing/forms",
    "/clients", "/counselors", "/dashboard", "/hours",
    "/insights/capacity", "/insights/money", "/insights/outcomes", "/insights/referrals", "/insights/reports",
    "/leads", "/paperwork", "/sops", "/tasks",
  ],
  "Job Search": [
    "/billing/documents", "/billing/forms", "/clients", "/counselors", "/dashboard",
    "/hours", "/leads", "/paperwork", "/sops", "/tasks",
  ],
  Reports: [
    "/billing/documents", "/billing/forms", "/clients", "/dashboard", "/hours",
    "/leads", "/paperwork", "/sops", "/tasks",
  ],
  Billing: [
    "/billing", "/billing/documents", "/billing/export", "/billing/forms", "/clients", "/counselors", "/dashboard",
    "/hours", "/leads", "/paperwork", "/sops",
  ],
};

// Screens a role must still reach, now that they sit under a sidebar entry
// rather than on one of their own.
const STILL_REACHED = {
  Admin: ["/dashboard/needs", "/billing/import", "/billing/warrants", "/admin/documents/records-request/x"],
  Billing: ["/dashboard/needs", "/billing/import", "/billing/warrants"],
  "Job Search": ["/dashboard/needs"],
  Reports: ["/dashboard/needs"],
};

for (const [role, expected] of Object.entries(EXPECTED)) {
  const actual = [...new Set(reachableFor(role).map((i) => navPath(i.href)))].sort();
  const gained = actual.filter((p) => !expected.includes(p));
  const lost = expected.filter((p) => !actual.includes(p));
  if (gained.length) fail(`${role} has gained ${gained.join(", ")} — deliberate?`);
  if (lost.length) fail(`${role} can no longer reach ${lost.join(", ")}`);
}
for (const [role, paths] of Object.entries(STILL_REACHED)) {
  for (const p of paths) {
    const inside = reachableFor(role).some((i) => p === navPath(i.href) || p.startsWith(navPath(i.href) + "/"));
    if (!inside) fail(`${role} can no longer reach ${p}`);
  }
}
if (!problems.length) ok("each role reaches exactly the screens it should, and the screens under them");

// Nobody sees a group with nothing in it.
for (const role of ["Admin", "Job Search", "Reports", "Billing"]) {
  for (const { group, items } of navFor(role)) {
    if (items.length === 0) fail(`${role} sees an empty "${group.label}" group`);
  }
}
ok("no role sees a group with nothing in it");

// Billing must not reach the screens that are not theirs.
const billing = reachableFor("Billing").map((i) => navPath(i.href));
for (const forbidden of ["/admin/people", "/insights/capacity", "/insights/money", "/tasks"]) {
  if (billing.includes(forbidden)) fail(`Billing can reach ${forbidden}`);
}
ok("Billing still cannot reach people, Insights or tasks");

// Insights is Admin's alone.
for (const role of ["Job Search", "Reports", "Billing"]) {
  const theirs = reachableFor(role).map((i) => navPath(i.href));
  const leak = theirs.filter((p) => p.startsWith("/insights"));
  if (leak.length) fail(`${role} can reach ${leak.join(", ")}, which is Admin's alone`);
}
ok("Insights is reachable by Admin only");

// ── access given to one person (0092) ────────────────────────
// A grant only adds. For every role, every area and every level it can be
// given at: nothing the role reached is lost, and everything gained belongs to
// that area. Then the things no grant may ever open.
const ROLES = ["Admin", "Job Search", "Reports", "Billing"];
const areaOf = new Map(NAV_GROUPS.flatMap((g) => g.items).map((i) => [navPath(i.href), i.area]));
let grantProblems = 0;
for (const role of ROLES) {
  const before = new Set(reachableFor(role).map((i) => navPath(i.href)));
  for (const area of AREAS) {
    for (const level of AREA_LEVELS[area]) {
      const after = new Set(reachableFor({ role, grants: [{ area, level }] }).map((i) => navPath(i.href)));
      const lost = [...before].filter((p) => !after.has(p));
      const strays = [...after].filter((p) => !before.has(p) && areaOf.get(p) !== area);
      if (lost.length) { grantProblems++; fail(`${role} given ${area} (${level}) loses ${lost.join(", ")} - a grant must only add`); }
      if (strays.length) { grantProblems++; fail(`${role} given ${area} (${level}) also reaches ${strays.join(", ")}, outside that area`); }
    }
  }
}
if (!grantProblems) ok("a grant only adds: no role loses a screen, and a grant opens only its own area");

// The navigation and the role defaults say the same thing: a role sees an
// area's screens exactly when ROLE_AREAS (and public.role_has_area) give it
// the area. Otherwise the menu and the database would disagree.
const mismatch = [];
for (const item of NAV_GROUPS.flatMap((g) => g.items).filter((i) => i.area)) {
  for (const role of ROLES) {
    const byNav = !item.roles || item.roles.includes(role);
    const byArea = Boolean(ROLE_AREAS[role][item.area]);
    if (byNav !== byArea) mismatch.push(`${role} / ${item.label}`);
  }
}
if (mismatch.length) fail(`the navigation and the role defaults disagree for: ${mismatch.join(", ")}`);
else ok("the sidebar and the role defaults agree on every area");

// No grant, of anything, opens the Admin group, Capacity or Statement
// approvals to somebody whose role does not include them.
const everything = AREAS.flatMap((area) => AREA_LEVELS[area].map((level) => ({ area, level })));
for (const role of ["Job Search", "Reports", "Billing"]) {
  const reach = reachableFor({ role, grants: everything }).map((i) => navPath(i.href));
  const never = ["/admin/people", "/admin/documents", "/admin/system", "/insights/capacity"];
  const leak = never.filter((p) => reach.includes(p));
  if (leak.length) fail(`${role} given every area reaches ${leak.join(", ")}, which no grant may open`);
  if (reach.includes("/hours") && reachableFor({ role, grants: everything }).some((i) => i.label === "Statement approvals")) {
    fail(`${role} given every area reaches Statement approvals`);
  }
}
ok("no grant opens Admin (People, Documents, System), Capacity or Statement approvals");

// ── everything that moved still answers ──────────────────────
const config = await readFile(new URL("../next.config.mjs", import.meta.url), "utf8");
const MOVED = [
  "/needs",
  "/forms",
  "/revenue",
  "/reports",
  "/outcomes",
  "/capacity",
  "/staff",
  "/contractors",
  "/exports",
  // the consolidation, September 2026
  "/referrals",
  "/billing/revenue",
  "/billing/position",
  "/admin/staff",
  "/admin/contractors",
  "/admin/inbox",
  "/admin/retention",
  "/admin/records-request",
  "/admin/settings",
  "/admin/note-templates",
  "/admin/access",
  "/admin/exports",
];
const missing = MOVED.filter((old) => !config.includes(`"${old}"`));
if (missing.length) {
  fail(`no redirect for: ${missing.join(", ")} — old links and bookmarks will 404`);
} else {
  ok(`all ${MOVED.length} moved paths redirect to where they went`);
}

// And none of them is still a route, which would shadow its own redirect.
const shadowed = MOVED.filter((old) => stat.has(old));
if (shadowed.length) {
  fail(`${shadowed.join(", ")} still exists as a page, so the redirect never fires`);
} else {
  ok("and none of them is still a page, so the redirects are the only answer");
}

// ── the client record: six tabs, and no old tab lost ─────────
// The twelve tabs before the consolidation. Each is either still a tab or
// mapped to the one that took it in, and no link in the code still names one
// that moved - a redirect is for bookmarks, not for our own links.
const OLD_CLIENT_TABS = [
  "activity", "overview", "intake", "notes", "forms", "files",
  "report", "placements", "tasks", "calendar", "authorizations", "payments",
];
if (CLIENT_TABS.length > 6) fail(`the client record has ${CLIENT_TABS.length} tabs; six is the most a screen may have`);
const unmapped = OLD_CLIENT_TABS.filter((k) => !CLIENT_TABS.some((t) => t.key === k) && !MOVED_CLIENT_TABS[k]);
if (unmapped.length) fail(`old client tabs with nowhere to go: ${unmapped.join(", ")}`);

async function sources(dir) {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const url = new URL(entry.name + (entry.isDirectory() ? "/" : ""), dir);
    if (entry.isDirectory()) out.push(...(await sources(url)));
    else if (/\.(ts|tsx)$/.test(entry.name)) out.push(url);
  }
  return out;
}
const movedKeys = Object.keys(MOVED_CLIENT_TABS).join("|");
const oldLink = new RegExp(String.raw`/clients/\$\{[^}]+\}\?tab=(${movedKeys})\b`);
const staleLinks = [];
for (const file of [
  ...(await sources(new URL("../app/", import.meta.url))),
  ...(await sources(new URL("../lib/", import.meta.url))),
]) {
  if (oldLink.test(await readFile(file, "utf8"))) staleLinks.push(decodeURIComponent(file.pathname.split("/zion-crm/")[1] ?? file.pathname));
}
if (staleLinks.length) fail(`links to a client tab that moved: ${staleLinks.join(", ")}`);
if (CLIENT_TABS.length <= 6 && !unmapped.length && !staleLinks.length) {
  ok(`the client record has ${CLIENT_TABS.length} tabs, every old tab redirects to one, and no link names an old tab`);
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- NAVIGATION VERIFIED ---");
