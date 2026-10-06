/**
 * The deploy check: sign in as the automated-check account and open every
 * screen it can reach. Any server error fails it.
 *
 *   SMOKE_BASE_URL=https://<deployment> SMOKE_EMAIL=… SMOKE_PASSWORD=… \
 *   SUPABASE_URL=… SUPABASE_ANON_KEY=… \
 *   node --experimental-strip-types scripts/smoke.mjs
 *
 * Run by .github/workflows/smoke.yml after every production deploy, with the
 * credentials from GitHub's secrets and nowhere else.
 *
 * Why this and not the build: Clients → Jobs passed the build and every check
 * and still failed for everybody who opened it (21 Sept 2026) - an error a
 * page throws while rendering comes back as HTTP 200 with the error folded
 * into the page, so the only way to know a screen works is to open it.
 *
 * What it opens, all as Job Search (the account can be nothing else, 0120):
 *   every screen in the navigation that role reaches, each ?tab= included;
 *   the Dashboard's needs lists;
 *   one client's record, every tab;
 *   one job and one counselor, where there are any.
 * It only reads. The account cannot write (0120), so a mistake here cannot
 * change anything either.
 */
import { readFileSync } from "node:fs";
import { createServerClient } from "@supabase/ssr";
import { readdir } from "node:fs/promises";
import { reachableFor, navPath } from "../lib/roles.ts";
import { CLIENT_TABS } from "../lib/client-tabs.ts";

const env = (k) => {
  const v = process.env[k];
  if (!v) {
    console.error(`  FAILED  ${k} is not set`);
    process.exit(2);
  }
  return v;
};
const BASE = env("SMOKE_BASE_URL").replace(/\/$/, "");
const BYPASS = process.env.VERCEL_AUTOMATION_BYPASS_SECRET ?? "";

// ── sign in, keeping the session in a jar the requests carry ──
// One of these per account. A role only ever sees its own screens, so
// Billing's - Invoices, Authorizations, the Service log, Export, Overview,
// Items - are opened by the Billing account and by nothing else (0129).
let cookie = () => "";
let supabase = null;

async function signIn(email, password, who) {
  const jar = new Map();
  supabase = createServerClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    cookies: {
      getAll: () => [...jar].map(([name, value]) => ({ name, value })),
      setAll: (list) => list.forEach(({ name, value }) => (value ? jar.set(name, value) : jar.delete(name))),
    },
  });
  const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });
  if (signInError) {
    console.error(`  FAILED  the ${who} account could not sign in: ${signInError.message}`);
    process.exit(1);
  }
  cookie = () => [...jar].map(([n, v]) => `${n}=${v}`).join("; ");
}

// ── what a failed screen looks like ───────────────────────────
// A render error is folded into a 200: Next leaves its digest in the page.
// It sits in the page's data escaped (\"digest\":\"1126557080\"), or as a
// data-dgst attribute; a numeric digest is an error, where a redirect or a
// not-found carries a word instead.
const ERROR_MARKS = [
  /\\?"digest\\?":\s*\\?"\d{3,}/,
  /data-dgst="\d{3,}"/,
  /Application error: a server-side exception has occurred/,
];

async function open(path) {
  let url = `${BASE}${path}`;
  for (let hop = 0; hop < 6; hop++) {
    const res = await fetch(url, {
      redirect: "manual",
      headers: { cookie: cookie(), ...(BYPASS ? { "x-vercel-protection-bypass": BYPASS } : {}) },
    });
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      const next = new URL(res.headers.get("location"), url);
      if (/^\/(login|no-access)/.test(next.pathname)) return { path, ok: false, why: `sent to ${next.pathname} - the account is signed out or has no access` };
      // The layout sends somebody to the dashboard from a screen they cannot
      // reach; the navigation says this one they can.
      if (next.pathname === "/dashboard" && !path.startsWith("/dashboard")) {
        return { path, ok: false, why: "sent to the dashboard - the navigation offers a screen this role cannot open" };
      }
      url = next.toString();
      continue;
    }
    const body = await res.text();
    if (res.status >= 500) return { path, ok: false, why: `HTTP ${res.status}`, body };
    if (res.status !== 200) return { path, ok: false, why: `HTTP ${res.status}` };
    const mark = ERROR_MARKS.find((m) => m.test(body));
    if (mark) return { path, ok: false, why: `a server error inside the page (${(body.match(mark) ?? [""])[0]})`, body };
    return { path, ok: true, body };
  }
  return { path, ok: false, why: "redirected in a loop" };
}

// ── the screens ───────────────────────────────────────────────
/** Every route with a page of its own, as a URL path. */
async function routes(dir = new URL("../app/(app)/", import.meta.url), prefix = "") {
  const out = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (entry.isDirectory()) {
      const segment = entry.name.startsWith("(") ? "" : `/${entry.name}`;
      out.push(...(await routes(new URL(`${entry.name}/`, dir), prefix + segment)));
    } else if (entry.name === "page.tsx") {
      out.push(prefix || "/");
    }
  }
  return out;
}


const needs = [...readFileSync(new URL("../lib/needs.ts", import.meta.url), "utf8").matchAll(/\{ key: "([a-z]+)", label:/g)].map((m) => m[1]);
const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const firstLink = (results, path, re) => results.find((x) => x.path === path)?.body?.match(re)?.[0] ?? null;

async function pass(role) {
  const paths = [...new Set(reachableFor(role).map((i) => i.href))];
  if (role === "Job Search") {
    paths.push(...needs.map((k) => `/dashboard/needs?list=${k}`));
    // Screens with tabs of their own, not in the navigation.
    paths.push("/counselors?tab=contact", "/counselors?tab=hours", "/sops/where");
  }

  const results = [];
  for (const p of paths) results.push(await open(p));

  /**
   * And whatever a hub's own cards point at.
   *
   * The navigation lists hubs, not the screens inside them, so ten screens
   * under Books could have shipped with a server error and nothing would
   * have said so - which is exactly the fault this check was written for,
   * when Clients to Jobs crashed on production after a route moved. A hub
   * draws its screens as cards, so following those needs no list anybody
   * has to maintain.
   */
  const inside = new Set();
  for (const r of results) {
    if (!r.body) continue;
    // A hub card, and nothing else: following every link on every page would
    // chase filters and anchors and report 404s that are not faults.
    for (const tag of r.body.matchAll(/<a[^>]*class="hub-card"[^>]*>/g)) {
      const href = (tag[0].match(/href="([^"]+)"/) ?? [])[1];
      if (href && href.startsWith("/") && !href.includes("#") && !paths.includes(href)) {
        inside.add(href);
      }
    }
  }
  for (const p of inside) results.push(await open(p));

  // One of each record, found on the list that links to it.
  const client = firstLink(results, "/clients", new RegExp(`/clients/${uuid}`));
  const job = firstLink(results, "/leads", new RegExp(`/leads/${uuid}`));
  const counselor = results.find((x) => x.path.startsWith("/counselors"))?.body?.match(new RegExp(`/counselors/${uuid}`))?.[0] ?? null;
  if (client) for (const t of CLIENT_TABS) results.push(await open(`${client}?tab=${t.key}`));
  if (job) results.push(await open(job));
  if (counselor) results.push(await open(counselor));

  // A billing item's own record, which is only reachable as Billing.
  const item = firstLink(results, "/billing?tab=items", new RegExp(`/billing/items/${uuid}`));
  if (item) results.push(await open(item));

  // A bank statement's own screen, found on the list of statements. The hub
  // walk above reaches every screen a card points at; this one is behind a
  // record, like a client or a billing item, so it is found the same way.
  const statement = firstLink(results, "/books/bank", new RegExp(`/books/bank/${uuid}`));
  if (statement) results.push(await open(statement));

  await supabase.auth.signOut().catch(() => {});
  return { results, client, item, statement };
}

// ── the verdict ───────────────────────────────────────────────
const all = [];
await signIn(env("SMOKE_EMAIL"), env("SMOKE_PASSWORD"), "automated-check");
const jobSearch = await pass("Job Search");
all.push(...jobSearch.results.map((r) => ({ ...r, role: "Job Search" })));

// The Billing account is optional: until it exists the check runs as it
// always has, and says which screens nobody is opening (0129).
if (process.env.SMOKE_BILLING_EMAIL && process.env.SMOKE_BILLING_PASSWORD) {
  await signIn(process.env.SMOKE_BILLING_EMAIL, process.env.SMOKE_BILLING_PASSWORD, "automated-check (billing)");
  const billing = await pass("Billing");
  all.push(...billing.results.map((r) => ({ ...r, role: "Billing" })));
  if (!billing.item) console.log("  note  no billing item was listed, so no item record was opened");
} else {
  /**
   * Said as an annotation, and counted properly.
   *
   * This was a note in the log, and the log is the place nobody reads: on
   * 6 Oct 2026 the fourteen screens of the books shipped with nothing having
   * opened them, because the only account that works is Job Search and the
   * books are Billing's. The count now includes the screens inside a hub,
   * since naming "/books" and meaning eleven screens understates the hole by
   * ten.
   */
  const unseenNav = [...new Set(reachableFor("Billing").map((i) => i.href))]
    .filter((h) => !jobSearch.results.some((r) => r.path === h));
  const underneath = (await routes()).filter(
    (r) => !r.includes("[") && unseenNav.some((h) => r.startsWith(navPath(h) + "/")),
  );
  const unseen = [...new Set([...unseenNav, ...underneath])].sort();
  console.log(
    `  note  no SMOKE_BILLING_EMAIL, so ${unseen.length} Billing screens were opened by nobody: ${unseen.join(", ")}`,
  );
  console.log(
    `::warning title=Screens nobody opened::${unseen.length} screens only Billing can reach were not opened, because SMOKE_BILLING_EMAIL and SMOKE_BILLING_PASSWORD are not set: ${unseen.join(", ")}`,
  );
}

const failed = all.filter((r) => !r.ok);
for (const r of all) console.log(`  ${r.ok ? "ok    " : "FAILED"}  ${r.role.padEnd(10)} ${r.path}${r.ok ? "" : `  - ${r.why}`}`);
console.log("");
if (!jobSearch.client) console.log("  note  no client record was listed, so no record tabs were opened");
if (failed.length) {
  console.error(`${failed.length} of ${all.length} screens failed on ${BASE}.`);
  process.exit(1);
}
console.log(`--- ALL ${all.length} SCREENS OPENED WITHOUT A SERVER ERROR (${BASE}) ---`);
