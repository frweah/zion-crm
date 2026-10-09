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

const hubs = new Set(NAV_GROUPS.map((g) => g.hub).filter(Boolean));
const orphans = [...stat].filter((r) => !covered(r) && r !== "/" && !hubs.has(r));
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
// "My clients today" (20 Sept 2026) is for the two roles that carry a
// caseload, and Admin, who sees everybody's of everything.
const EXPECTED = {
  Admin: [
    "/admin/documents", "/admin/people", "/admin/settings-hub", "/admin/system",
    "/billing",
    "/calendar", "/clients", "/counselors", "/dashboard", "/hours",
    "/directory", "/forms-and-checklists", "/insights/capacity", "/insights/money", "/insights/outcomes", "/insights/referrals",
    "/books", "/insights/reports", "/updates",
    "/leads", "/mail", "/messages", "/messages/texts", "/my-clients", "/my-day", "/forms-and-checklists", "/paperwork", "/requests", "/sops", "/tasks",
    "/time-clock", "/updates",
  ],
  // Billing → Forms and Report & bill were theirs and are gone (Billing
  // Simplification Brief §9). The job itself is not: a signed packet is sent
  // from the client's own record, which they still reach. What they no longer
  // have is a screen of blank forms and a second way to bill.
  "Job Search": [
    "/calendar", "/clients", "/counselors", "/dashboard", "/directory",
    "/hours", "/leads", "/mail", "/messages", "/messages/texts", "/my-clients", "/my-day", "/forms-and-checklists", "/paperwork", "/requests", "/sops",
    "/tasks", "/time-clock", "/updates",
  ],
  Reports: [
    "/calendar", "/clients", "/dashboard", "/directory", "/hours",
    "/leads", "/mail", "/messages", "/messages/texts", "/my-clients", "/my-day", "/forms-and-checklists", "/paperwork", "/requests", "/sops", "/tasks",
    "/time-clock", "/updates",
  ],
  Billing: [
    "/billing", "/calendar", "/clients", "/counselors",
    "/dashboard", "/directory",
    "/books", "/hours", "/leads", "/mail", "/messages", "/messages/texts", "/forms-and-checklists", "/my-day", "/paperwork", "/requests", "/sops", "/time-clock", "/updates",
  ],
};

// Screens a role must still reach, now that they sit under a sidebar entry
// rather than on one of their own.
const STILL_REACHED = {
  Admin: ["/dashboard/needs", "/billing/warrants", "/admin/documents/records-request/x"],
  Billing: ["/dashboard/needs", "/billing/warrants"],
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

// ── the hubs (Design language, §1) ───────────────────────────
// Home · Work · Communication · Billing · HR · Admin, in that order, and
// nothing else. The work of the practice is one hub - clients, their tasks,
// the jobs and the counselors - and everything that arrives is another.
const HUBS = ["Home", "Work", "Communication", "Billing", "HR", "Admin"];
const labels = NAV_GROUPS.map((g) => g.label);
if (labels.join("|") !== HUBS.join("|")) fail(`the sidebar is ${labels.join(" · ")}, not ${HUBS.join(" · ")}`);

// A hub opens on its own page of cards, and that page has to exist.
for (const g of NAV_GROUPS) {
  if (g.hub && !stat.has(g.hub)) fail(`${g.label} says its hub is ${g.hub}, and there is no page there`);
}

const groupOf = (href) => NAV_GROUPS.find((g) => g.items.some((i) => navPath(i.href) === href))?.label;
const HOMES = {
  "/tasks": "Work", "/clients": "Work", "/leads": "Work", "/counselors": "Work",
  "/mail": "Communication", "/messages": "Communication", "/messages/texts": "Communication",
  "/calendar": "Communication", "/hours": "HR", "/paperwork": "HR", "/sops": "HR", "/admin/people": "HR",
  "/insights/money": "Admin", "/insights/reports": "Admin", "/admin/documents": "Admin", "/admin/system": "Admin",
};
const misplaced = Object.entries(HOMES).filter(([href, home]) => groupOf(href) !== home);
if (misplaced.length) fail(`in the wrong group: ${misplaced.map(([h, g]) => `${h} (should be ${g}, is ${groupOf(h)})`).join(", ")}`);
const hrFor = (role) => navFor(role).find((g) => g.group.key === "hr")?.items.map((i) => i.label) ?? [];
if (!hrFor("Admin").includes("People") || !hrFor("Admin").includes("Contractors")) fail("Admin does not see People and Contractors under HR");
if (["Job Search", "Reports", "Billing"].some((r) => hrFor(r).includes("People") || hrFor(r).includes("Contractors"))) {
  fail("somebody other than Admin sees People or Contractors under HR");
}
if (!problems.length) ok("six groups, in order; every screen in its home; People and Contractors under HR for Admin only");

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
  // the second consolidation, 21 September 2026: the new group names
  "/inbox",
  "/chat",
  "/texts",
  "/website-chat",
  // "/hr" was a redirect to /hours and is a hub page of its own now
  // (Design language, §1), so it is no longer in this list.
  "/my-work",
  "/certifications",
  "/insights",
  "/dashboard/tasks",
  // Billing cut to two tabs (Billing Simplification Brief §9). The forms, the
  // signed authorization, the checklist and Report & bill are on the
  // authorization record; the month-end export and the rate schedule are
  // Admin's.
  "/billing/forms",
  "/billing/report",
  "/billing/export",
  "/billing/import",
  // The item's own screen, which §10 removed with the record.
  "/billing/items",
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
// Six was the consolidation's limit. Messages (Messaging brief, A) makes
// seven, which the owner chose deliberately on 19 Sept 2026 over burying the
// client's texts inside Activity. Seven is the limit now, and an eighth is a
// conversation, not a commit.
if (CLIENT_TABS.length > 7) fail(`the client record has ${CLIENT_TABS.length} tabs; seven is the most a screen may have`);
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
  if (oldLink.test(await readFile(file, "utf8"))) staleLinks.push(rel(file));
}
if (staleLinks.length) fail(`links to a client tab that moved: ${staleLinks.join(", ")}`);
if (CLIENT_TABS.length <= 7 && !unmapped.length && !staleLinks.length) {
  ok(`the client record has ${CLIENT_TABS.length} tabs, every old tab redirects to one, and no link names an old tab`);
}

// ── nothing offers to raise an invoice ───────────────────────
//
// §10: there is one door to a bill and it is entering an authorization. The
// check is on what a person is *offered*, not on the word itself - the history
// of this practice is full of invoices and the screens may say so. What they
// may not do is put a button, a link, a menu item or a quick-add entry in front
// of somebody that makes one.
const OFFERS = [
  // A control that offers to make one. A column heading that says "Invoiced"
  // is not an offer, so this looks for the verbs.
  /<(?:button|a|Link)[^>]*>\s*(?:New|Raise|Create|Add|Make)\s+(?:an?\s+)?invoice/i,
  /(?:New|Raise|Create|Add|Make)\s+(?:an?\s+)?invoice\s*<\/(?:button|a|Link)>/i,
  // Writing one, or naming the table at all.
  /from\(["']invoices["']\)/,
  /rpc\(["'](?:draft_invoice_for_authorization|setInvoiceStatus)["']/,
  // A quick-add entry for one. Only quick-add declares entries this way.
  /QUICK_ADD[\s\S]{0,400}?invoice/i,
];
const offenders = [];
for (const file of [
  ...(await sources(new URL("../app/", import.meta.url))),
  ...(await sources(new URL("../lib/", import.meta.url))),
]) {
  const text = await readFile(file, "utf8");
  if (OFFERS.some((re) => re.test(text))) {
    offenders.push(rel(file));
  }
}
if (offenders.length) {
  fail(`something still offers to raise an invoice: ${offenders.join(", ")}`);
} else {
  ok("nothing offers to raise an invoice, and nothing writes one");
}

// ── and nothing writes a bill around the door ────────────────
//
// §10: entering an authorization is the only thing that creates a bill, and
// add_authorization() is where that happens. 0168 revoked direct insert from
// everybody, which means a screen that still inserts does not fail review - it
// fails in front of whoever is using it.
//
// That is exactly what happened: the PDF import route kept its own insert and
// was refused with a permission error for two deploys, on the route this brief
// makes the primary one. verify_one_door asks which *functions* write a bill;
// nothing asked about the app. This does.
// Chained to that from and nothing else: whitespace only in between, so an
// update here and an unrelated insert thirty lines later is not a finding.
const DIRECT_WRITE = /from\(["']authorizations["']\)\s*\.(insert|upsert)\(/;
const roundTheDoor = [];
for (const file of [
  ...(await sources(new URL("../app/", import.meta.url))),
  ...(await sources(new URL("../lib/", import.meta.url))),
]) {
  if (DIRECT_WRITE.test(await readFile(file, "utf8"))) {
    roundTheDoor.push(rel(file));
  }
}
if (roundTheDoor.length) {
  fail(`these create an authorization without going through add_authorization: ${roundTheDoor.join(", ")}`);
} else {
  ok("nothing creates a bill except through add_authorization");
}

// ── every link goes somewhere ─────────────────────────────────
//
// A link to a route that was removed is a 404 for whoever clicks it, and
// nothing else catches it: tsc does not read strings, the build renders pages
// rather than following links, and the smoke test opens the screens the
// navigation lists - not the links those screens emit. Clicking a client under
// Billing gave a 404 for exactly that reason.
//
// So: collect the routes that exist, collect the links the app writes, and
// report any link that matches neither a route nor a redirect.
const ROUTE_FILES = ["page.tsx", "route.ts"];
async function realRoutes(dir, prefix = "") {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      // (groups) do not appear in the URL; @slots and _private are not routes.
      if (entry.name.startsWith("@") || entry.name.startsWith("_")) continue;
      const segment = entry.name.startsWith("(") ? "" : `/${entry.name}`;
      out.push(...(await realRoutes(new URL(`${entry.name}/`, dir), prefix + segment)));
    } else if (ROUTE_FILES.includes(entry.name)) {
      out.push(prefix || "/");
    }
  }
  return out;
}
const routePaths = await realRoutes(new URL("../app/", import.meta.url));

// A route with [id] in it matches a link with anything in that position. The
// catch-all [...slug] matches the rest of the path.
const routeMatchers = routePaths.map((r) => ({
  path: r,
  re: new RegExp(
    "^" +
      r
        .replace(/\[\.\.\.[^\]]+\]/g, "@@REST@@")
        .replace(/\[[^\]]+\]/g, "@@ONE@@")
        .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
        .replace(/@@REST@@/g, ".+")
        .replace(/@@ONE@@/g, "[^/]+") +
      "$",
  ),
}));

// Where a removed path is sent instead. Read from the config so the two
// cannot drift.
const redirectSources = [...config.matchAll(/^\s*"(\/[^"]*)":\s*"/gm)].map((m) => m[1]);
const redirectMatchers = redirectSources.map(
  (r) =>
    new RegExp(
      "^" +
        r
          .replace(/:[a-zA-Z]+\*/g, "@@REST@@")
          .replace(/:[a-zA-Z]+/g, "@@ONE@@")
          .replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
          .replace(/@@REST@@/g, ".+")
          .replace(/@@ONE@@/g, "[^/]+") +
        "$",
    ),
);

/**
 * The links the app writes, as paths.
 *
 * Both shapes are read: href="/billing" and href={`/clients/${id}?tab=billing`}.
 * An interpolation becomes one path segment, which is what it always is in
 * practice - an id. The query and the fragment are dropped: what is being
 * checked is whether the route exists.
 */
const LINK = /href=(?:"(\/[^"]*)"|\{`(\/[^`]*)`\})/g;
const linkPaths = new Map();
for (const file of [
  ...(await sources(new URL("../app/", import.meta.url))),
  ...(await sources(new URL("../lib/", import.meta.url))),
]) {
  const name = rel(file);
  const text = await readFile(file, "utf8");
  for (const m of text.matchAll(LINK)) {
    const raw = m[1] ?? m[2];
    /**
     * An interpolation is a path segment, or it is a suffix on one.
     *
     * The text says which: `/billing/items/${id}` has it right after a slash,
     * so it is a segment and the route has to have a [param] there.
     * `/books/reports/export${query({...})}` has it stuck to the end of a
     * segment, so it is building a query string and what matters is the path in
     * front of it.
     *
     * Getting this wrong in the generous direction is how the first version of
     * this check passed a link to the removed /billing/items/<id>: it dropped
     * the last segment and found /billing/items, which had a redirect. Braces
     * are counted rather than matched to the first "}", because an
     * interpolation can contain a call with braces of its own.
     */
    let path = "";
    for (let i = 0; i < raw.length; i++) {
      if (raw[i] === "$" && raw[i + 1] === "{") {
        const isSegment = i === 0 || raw[i - 1] === "/";
        let depth = 0;
        i += 1;
        for (; i < raw.length; i++) {
          if (raw[i] === "{") depth += 1;
          else if (raw[i] === "}") {
            depth -= 1;
            if (depth === 0) break;
          }
        }
        if (!isSegment) break;  // a suffix, not a segment: the path ends here
        path += "x";
      } else {
        path += raw[i];
      }
    }
    path = path.split("?")[0].split("#")[0].replace(/\/+$/, "");
    if (!path || path === "/") continue;
    // A path whose own first segment is worked out at runtime cannot be checked
    // here: /${screen} could be any screen. The navigation checks cover those.
    if (/^\/x(\/|$)/.test(path)) continue;
    if (!linkPaths.has(path)) linkPaths.set(path, new Set());
    linkPaths.get(path).add(name);
  }
}

const lands = (path) =>
  routeMatchers.some((r) => r.re.test(path)) || redirectMatchers.some((r) => r.test(path));

const dead = [];
for (const [path, where] of linkPaths) {
  if (lands(path)) continue;
  dead.push(`${path} (from ${[...where].join(", ")})`);
}
if (dead.length) {
  for (const d of dead) fail(`a link goes nowhere: ${d}`);
} else {
  ok(`all ${linkPaths.size} linked paths reach a route or a redirect`);
}

// ── a parameter needs a ? to hang off ────────────────────────
//
// The dead-link check above reads the links it can see written out. This one
// catches the links that are built: `${base}&doc=${id}` is a parameter appended
// to something that may carry no query at all, and when it does not, "&doc=<id>"
// is part of the path. That is what Open on every row of the documents-folder
// queue emitted after §9 changed the base from "/billing?tab=authorizations" to
// "/billing" - eighty rows, each answering 404, and the link was invisible to
// every check because it came out of a callback rather than out of an href.
//
// The rule: in a URL-shaped template literal, a "&name=" must have a "?" in
// front of it. Where it cannot, the query belongs in URLSearchParams, which
// gets the separator right by construction.
const PARAM_LITERAL = /`((?:\/|\$\{)[^`]{0,200}?)`/g;
const loose = [];
for (const file of [
  ...(await sources(new URL("../app/", import.meta.url))),
  ...(await sources(new URL("../lib/", import.meta.url))),
]) {
  const text = await readFile(file, "utf8");
  for (const m of text.matchAll(PARAM_LITERAL)) {
    const lit = m[1];
    const amp = lit.search(/&[a-zA-Z_]+=/);
    if (amp < 0) continue;
    const q = lit.indexOf("?");
    if (q >= 0 && q < amp) continue;
    loose.push(`${rel(file)}: \`${lit}\``);
  }
}
if (loose.length) {
  for (const l of loose) fail(`a parameter is added with & to something that may have no query: ${l}`);
} else {
  ok("every built link puts its parameters behind a ?, or composes them");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- NAVIGATION VERIFIED ---");
