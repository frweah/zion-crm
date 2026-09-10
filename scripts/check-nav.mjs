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
import { NAV_GROUPS, navFor, navPath, reachableFor } from "../lib/roles.ts";

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
const EXPECTED = {
  Admin: [
    "/admin/access", "/admin/contractors", "/admin/exports", "/admin/inbox",
    "/admin/note-templates",
    "/admin/settings", "/admin/staff",
    "/billing", "/billing/forms", "/billing/import", "/billing/revenue",
    "/clients", "/counselors", "/dashboard", "/dashboard/needs", "/hours",
    "/insights/capacity", "/insights/outcomes", "/insights/reports", "/leads",
    "/paperwork", "/referrals", "/sops", "/tasks",
  ],
  "Job Search": [
    "/admin/inbox", "/billing/forms", "/clients", "/counselors", "/dashboard", "/dashboard/needs",
    "/hours", "/leads", "/paperwork", "/referrals", "/sops", "/tasks",
  ],
  Reports: [
    "/admin/inbox", "/billing/forms", "/clients", "/dashboard", "/dashboard/needs", "/hours",
    "/insights/outcomes", "/insights/reports", "/leads", "/paperwork",
    "/referrals", "/sops", "/tasks",
  ],
  Billing: [
    "/admin/exports", "/admin/inbox", "/billing", "/billing/forms", "/billing/import",
    "/billing/revenue", "/clients", "/counselors", "/dashboard",
    "/dashboard/needs", "/hours", "/leads", "/paperwork", "/sops",
  ],
};

for (const [role, expected] of Object.entries(EXPECTED)) {
  const actual = [...new Set(reachableFor(role).map((i) => navPath(i.href)))].sort();
  const gained = actual.filter((p) => !expected.includes(p));
  const lost = expected.filter((p) => !actual.includes(p));
  if (gained.length) fail(`${role} has gained ${gained.join(", ")} — deliberate?`);
  if (lost.length) fail(`${role} can no longer reach ${lost.join(", ")}`);
}
if (!problems.length) ok("each role reaches exactly the screens it reached before");

// Nobody sees a group with nothing in it.
for (const role of ["Admin", "Job Search", "Reports", "Billing"]) {
  for (const { group, items } of navFor(role)) {
    if (items.length === 0) fail(`${role} sees an empty "${group.label}" group`);
  }
}
ok("no role sees a group with nothing in it");

// Billing must not reach the screens that are not theirs.
const billing = reachableFor("Billing").map((i) => navPath(i.href));
for (const forbidden of ["/admin/staff", "/insights/capacity", "/tasks"]) {
  if (billing.includes(forbidden)) fail(`Billing can reach ${forbidden}`);
}
ok("Billing still cannot reach staff, capacity or tasks");

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

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- NAVIGATION VERIFIED ---");
