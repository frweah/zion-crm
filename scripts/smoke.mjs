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
import { reachableFor, navFor, navPath, hubBack, NAV_GROUPS } from "../lib/roles.ts";
import { CLIENT_TABS } from "../lib/client-tabs.ts";
import { retrying } from "./retry-screen.mjs";

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

/**
 * The practice's one permanent fixture client.
 *
 * Inactive, on nobody's board, and the single name
 * supabase/verify_zz_no_fixtures.sql permits to be on file. Two steps below
 * need a client to exist on production and must not create one.
 */
const SMOKE_CLIENT = "ZZ Smoke Board";

// ── sign in, keeping the session in a jar the requests carry ──
// One of these per account. A role only ever sees its own screens, so
// Billing's - Invoices, Authorizations, the Service log, Export, Overview,
// Items - are opened by the Billing account and by nothing else (0129).
/**
 * The cookies, kept the way a browser keeps them.
 *
 * This used to snapshot the jar once at sign-in and send that same string on
 * every request for the rest of the run, ignoring everything the server sent
 * back. A browser does not do that, and the difference is not cosmetic: the
 * middleware's session check can rotate the refresh token, and a client still
 * holding the old one is a client the Auth service will stop vouching for.
 *
 * On 15 Oct 2026 that turned a real middleware fault - an error from the Auth
 * service being read as "this session is revoked" - into eighteen screens
 * passing and every screen after them redirecting to /login, which rolled
 * production back over a .gitignore change. The middleware was fixed; this is
 * the other half, so a stale refresh token cannot fail a run on its own.
 *
 * One jar for the process, emptied when a different account signs in - two
 * accounts sharing a jar would send the first one's session with the second
 * one's requests.
 */
const jar = new Map();
const cookie = () => [...jar].map(([n, v]) => `${n}=${v}`).join("; ");

/** Apply a response's Set-Cookie headers to the jar, additions and removals. */
function remember(res) {
  for (const line of res.headers.getSetCookie?.() ?? []) {
    const [pair, ...attributes] = line.split(";");
    const eq = pair.indexOf("=");
    if (eq < 1) continue;
    const name = pair.slice(0, eq).trim();
    const value = pair.slice(eq + 1).trim();
    // A deletion is an empty value, Max-Age=0, or a date already past - all
    // three are how a server takes a cookie away.
    const expires = attributes
      .map((a) => a.match(/^\s*expires\s*=(.*)$/i))
      .find(Boolean);
    const taken =
      value === "" ||
      attributes.some((a) => /^\s*max-age\s*=\s*0+\s*$/i.test(a)) ||
      (expires && new Date(expires[1]) <= new Date());
    if (taken) jar.delete(name);
    else jar.set(name, value);
  }
}

let supabase = null;

/**
 * Signing in, which first signs out whoever was signed in.
 *
 * The sign-out used to be the last line of pass(), and on 5 November that put
 * it one line before a request: /team was asked for after the pass that had
 * just signed the account out, so the middleware sent it to /login and two
 * deploys rolled back over it. The message said "the account is signed out",
 * which was exactly true and read like a guess.
 *
 * Here it cannot happen. A sign-out belongs before the next session rather
 * than after the last request of the old one, and there is one place it
 * happens instead of one per pass.
 */
async function signIn(email, password, who) {
  if (supabase) await supabase.auth.signOut().catch(() => {});
  jar.clear();
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

/**
 * Open one screen, once.
 *
 * Every failure carries a `kind` as well as a sentence, and the two are for
 * different readers: the sentence is for whoever opens the issue, the kind is
 * for `scripts/retry-screen.mjs`, which decides from it whether asking again
 * in ten seconds could answer differently. The sentences here have been
 * reworded three times and will be again, so nothing is allowed to depend on
 * their words.
 *
 * `check-retry.mjs` asserts that every failure below carries one. A failure
 * with no kind is retried rather than refused a second look, which is the
 * safe side to be wrong on, but it is still wrong - a settled failure asked
 * twice costs the run ten seconds for an answer it already had.
 *
 * Nothing calls this directly. `open` below is this wrapped in the rule.
 */
async function openOnce(path) {
  /**
   * No session, said as no session.
   *
   * Every path this opens needs one, so an empty jar is the check's own
   * doing and not the screen's. It used to arrive as "sent to /login - the
   * account is signed out or has no access", three possibilities in one
   * sentence, and the true one sounded like the least likely. Two days went
   * into the other two.
   */
  if (![...jar.keys()].some((name) => /^sb-.*-auth-token/.test(name))) {
    return { path, ok: false, kind: "no-session", why: "there is no session in the jar - the check signed itself out before asking for this" };
  }
  let url = `${BASE}${path}`;
  for (let hop = 0; hop < 6; hop++) {
    /**
     * A request that never arrived is a failure like any other, rather than
     * the end of the run.
     *
     * It used to throw out of here and take the whole check down with it,
     * which reads as "the deploy check fell over" - no rollback, and nothing
     * known about any screen after this one. A dropped connection is also the
     * single likeliest thing the second look exists for, and a retry that
     * cannot survive the first throw is a retry for nothing.
     */
    let res;
    try {
      res = await fetch(url, {
        redirect: "manual",
        headers: { cookie: cookie(), ...(BYPASS ? { "x-vercel-protection-bypass": BYPASS } : {}) },
      });
    } catch (err) {
      return { path, ok: false, kind: "unreachable", why: `the request never arrived: ${err instanceof Error ? err.message : err}` };
    }
    // Before anything is decided about the response: a refreshed session
    // arrives as Set-Cookie on a redirect just as often as on a page.
    remember(res);
    if (res.status >= 300 && res.status < 400 && res.headers.get("location")) {
      const next = new URL(res.headers.get("location"), url);
      if (/^\/(login|no-access)/.test(next.pathname)) return { path, ok: false, kind: "sent", why: `sent to ${next.pathname} - the account is signed out or has no access` };
      // The layout sends somebody to the dashboard from a screen they cannot
      // reach; the navigation says this one they can.
      if (next.pathname === "/dashboard" && !path.startsWith("/dashboard")) {
        return { path, ok: false, kind: "sent", why: "sent to the dashboard - the navigation offers a screen this role cannot open" };
      }
      url = next.toString();
      continue;
    }
    const body = await res.text();
    if (res.status >= 500) return { path, ok: false, kind: "status", why: `HTTP ${res.status}`, body };
    if (res.status !== 200) return { path, ok: false, kind: "status", why: `HTTP ${res.status}` };
    const mark = ERROR_MARKS.find((m) => m.test(body));
    if (mark) return { path, ok: false, kind: "in-page", why: `a server error inside the page (${(body.match(mark) ?? [""])[0]})`, body };
    return { path, ok: true, body };
  }
  return { path, ok: false, kind: "loop", why: "redirected in a loop" };
}

/**
 * The rule: a screen that fails is asked once more, ten seconds later, and
 * two failures in a row is a real one (owner, 20 November 2026).
 *
 * `scripts/retry-screen.mjs` holds it, so the behaviour can be put to
 * fixtures instead of only to production. Everything in this file opens
 * screens through this `open`, and a GET is the only thing it retries: the
 * action posts below go out through their own fetch, because posting an
 * action twice is a write, and writing twice is the one thing this check must
 * never do on a deploy.
 */
const retry = retrying({
  open: openOnce,
  wait: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
});
const open = retry.open;

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


/** Every path the sidebar offers, to any role, including the hub roots. */
const NAVIGATION = new Set(
  NAV_GROUPS.flatMap((g) => [
    ...(g.hub ? [navPath(g.hub)] : []),
    ...g.items.map((i) => navPath(i.href)),
  ]),
);

const needs = [...readFileSync(new URL("../lib/needs.ts", import.meta.url), "utf8").matchAll(/\{ key: "([a-z]+)", label:/g)].map((m) => m[1]);
const uuid = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const firstLink = (results, path, re) => results.find((x) => x.path === path)?.body?.match(re)?.[0] ?? null;

/**
 * Whether a followed href is a screen at all.
 *
 * A stylesheet is not. This followed every `href="/…"` in the HTML, and a
 * page's own `<link rel="stylesheet" href="/_next/static/css/….css">` is one
 * of those. It never mattered while the client record was never opened; the
 * first deploy that opened one followed the stylesheet, found no Team bubble
 * on it - correctly, it is a CSS file - and rolled production back.
 */
const isScreenLink = (href) => {
  // The extension is judged on the path, not on the query: a filter value
  // may contain a dot and is not a file name.
  const path = href.split("?")[0];
  return !/^\/(login|logout|api|_next)\b/.test(path) && !/\.[a-z0-9]{2,12}$/i.test(path);
};

// It tests itself, because the last regex in this file that nobody tested
// matched every USOR authorization number and failed nineteen screens.
for (const [href, want] of [
  ["/clients/5f1c0a16-0000-0000-0000-000000000000", true],
  ["/billing?tab=hours", true],
  ["/clients?tab=all&q=ZZ", true],
  ["/clients?tab=all&q=a.b", true],
  ["/_next/static/css/7e45d8f700681ac3.css?dpl=dpl_8wfpKEEER", false],
  ["/favicon.ico", false],
  // Eleven characters, which is why the first version of this let it through
  // and asked a web app manifest for the Team bubble.
  ["/manifest.webmanifest", false],
  ["/zion-logo.png", false],
  ["/logout", false],
]) {
  if (isScreenLink(href) !== want) {
    console.error(`  FAILED  the link filter calls ${href} ${want ? "not a screen" : "a screen"}`);
    process.exit(1);
  }
}

/** Every hub tab either account found a way back on, across both passes. */
const backChecked = [];

async function pass(role) {
  /**
   * The hubs this role can see, and then the screens inside them.
   *
   * The hubs were not swept at all until 18 Oct 2026, and that is how three
   * of them shipped unreachable: canReach refused /work, /communication and
   * /hr to every role, the sidebar headings and three of the four tabs on
   * the phone bar pointed at them, and nothing here opened one to find out.
   * A hub is a screen; it is swept like a screen.
   */
  const hubs = navFor(role)
    .map((g) => g.group.hub)
    .filter((h) => typeof h === "string");
  const paths = [...new Set([...hubs, ...reachableFor(role).map((i) => i.href)])];
  if (role === "Job Search") {
    paths.push(...needs.map((k) => `/dashboard/needs?list=${k}`));
    // Screens with tabs of their own, not in the navigation.
    paths.push("/counselors?tab=contact", "/counselors?tab=hours", "/sops/where");
    /*
     * The reports board's other three views (0377). The navigation names the
     * board and nothing under it, so the previous month, the template list
     * and the sent log would have been three screens nobody opened - and the
     * sent log has never had a row to draw, which is exactly the shape of
     * thing that renders once and then throws when it has data.
     *
     * Opened as Job Search because the board is everybody's: every active
     * staff member may open, edit, assemble and mark Reviewed on any monthly
     * report, which is ruling 1 of the same day.
     */
    const lastMonth = new Date();
    lastMonth.setUTCDate(1);
    lastMonth.setUTCMonth(lastMonth.getUTCMonth() - 1);
    paths.push(
      `/client-reports?month=${lastMonth.toISOString().slice(0, 10)}`,
      "/client-reports?tab=templates",
      "/client-reports?tab=sent",
    );
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
    for (const tag of r.body.matchAll(/<a\b[^>]*class="hub-card"[^>]*>/g)) {
      const href = (tag[0].match(/href="([^"]+)"/) ?? [])[1];
      if (href && href.startsWith("/") && !href.includes("#") && !paths.includes(href)) {
        inside.add(href);
      }
    }
  }
  for (const p of inside) results.push(await open(p));

  // One of each record, found on the list that links to it.
  // The same gap as in the per-role loop below: /clients opens on Mine, and
  // this account is on nobody's caseload, so the list linked to no record and
  // none of the seven tabs was opened on any deploy.
  let client = firstLink(results, "/clients", new RegExp(`/clients/${uuid}`));
  if (!client) {
    const { data: anyone } = await supabase.from("clients").select("id").eq("status", "Active").limit(1);
    if (anyone?.[0]) client = `/clients/${anyone[0].id}`;
  }
  const job = firstLink(results, "/leads", new RegExp(`/leads/${uuid}`));
  const counselor = results.find((x) => x.path.startsWith("/counselors"))?.body?.match(new RegExp(`/counselors/${uuid}`))?.[0] ?? null;
  if (client) for (const t of CLIENT_TABS) results.push(await open(`${client}?tab=${t.key}`));
  if (job) results.push(await open(job));
  if (counselor) results.push(await open(counselor));

  /**
   * An authorization's own record, which is only reachable as Billing.
   *
   * This looked for a billing item at /billing?tab=items, and §§9 and 10
   * removed both the tab and the record - so it found nothing, opened nothing,
   * and said so in a note that reads the same whether the screen is missing or
   * merely empty. The authorization record is where the work happens now: the
   * checklist, the papers, the submit.
   */
  const item = firstLink(results, "/billing", new RegExp(`/billing/authorizations/${uuid}`));
  if (item) results.push(await open(item));

  /**
   * And every other link the working list puts in front of somebody.
   *
   * Opening the screens the navigation lists is not enough: clicking a client
   * on the working list gave a 404, and nothing caught it, because the link was
   * on a page the check opened rather than being a page itself. So the links a
   * page emits are followed too - the client, the record, the warrant, the
   * filters - and a 404 among them fails the run.
   *
   * Only the Billing list and the client's Billing tab, and bounded: this is a
   * check on the screens this brief rebuilt, not a crawl of the whole site.
   */
  const followFrom = [
    results.find((x) => x.path === "/billing"),
    client ? results.find((x) => x.path === `${client}?tab=billing`) : null,
  ].filter((x) => x?.ok && x.body);

  const followed = new Set(results.map((r) => r.path));
  for (const from of followFrom) {
    const links = new Set();
    for (const m of from.body.matchAll(/href="(\/[^"]*)"/g)) {
      // The fragment is dropped, not refused. Refusing any href that carried
      // one is why this never followed Open on the documents-folder queue:
      // that link ends "#from-documents", so the one link that was 404ing was
      // the one link the follower skipped.
      const href = m[1].replace(/&amp;/g, "&").split("#")[0];
      if (!href) continue;
      // Already opened, or a sign-out that would end the run.
      if (followed.has(href) || !isScreenLink(href)) continue;
      // The sidebar is in every page's HTML, so its own entries are not this
      // page's links: following them warned three times a run about hub roots
      // a role cannot open, which is a question about the sidebar and is
      // already the navigation checks' business. An annotation that fires every
      // time is an annotation nobody reads.
      if (NAVIGATION.has(navPath(href))) continue;
      links.add(href);
      if (links.size >= 20) break;
    }
    for (const href of links) {
      followed.add(href);
      const r = await open(href);
      /**
       * A 404 or a server error is a fault, full stop - the link is in front of
       * somebody and it does not work.
       *
       * Being sent to the dashboard is not. A page may carry a link to
       * somewhere this role cannot go, and that is a judgement about what to
       * show rather than a broken link; failing on it would roll a deployment
       * back over a design question. It is said, and counted as said.
       */
      if (!r.ok && /sent to the dashboard/.test(r.why ?? "")) {
        console.log(
          `::warning title=A link this role cannot follow::${from.path} links to ${href}, which ${role} cannot open.`,
        );
        continue;
      }
      results.push({ ...r, why: r.ok ? r.why : `${r.why} - followed from ${from.path}` });
    }
  }

  /**
   * Open, on the first row of "From the documents folder" (§9).
   *
   * Clicked rather than guessed at: the href is read off the page, which is the
   * only way to catch a link that is built wrong. Every row of this queue
   * answered 404 for eighty documents, and nothing noticed - the screens the
   * navigation lists were all fine, and this link is on one of them rather than
   * being one of them.
   *
   * The assertion is not just that it answers. The row that was clicked shows
   * as the open one, which is what says the document view - its PDF and the
   * pick-and-confirm form - actually came up.
   */
  const billingBody = results.find((x) => x.path === "/billing")?.body ?? "";
  const openHref = billingBody.match(/href="(\/billing\?[^"]*doc=[0-9a-f-]{36}[^"]*)"/)?.[1];
  if (openHref) {
    const opened = await open(openHref.replace(/&amp;/g, "&").split("#")[0]);
    results.push(opened);
    if (opened.ok && !/chip gold">Open/.test(opened.body ?? "")) {
      results.push({
        path: `${openHref} (the document view)`,
        ok: false,
        why: "the row opened but the document was not shown as the open one",
      });
    }
  } else if (role === "Billing") {
    console.log(
      "::warning title=Nothing to confirm::" +
        'No row of "From the documents folder" offered an Open link, so the pending-document view was not opened by this run.',
    );
  }

  // A bank statement's own screen, found on the list of statements. The hub
  // walk above reaches every screen a card points at; this one is behind a
  // record, like a client or a billing item, so it is found the same way.
  const statement = firstLink(results, "/books/bank", new RegExp(`/books/bank/${uuid}`));
  if (statement) results.push(await open(statement));

  /**
   * The way back off a hub's tab, in the page rather than in the source.
   *
   * check-screens reads the files and can say that the layout draws the arrow.
   * It cannot say that the arrow arrives: it is a client component reading the
   * current tab, so whether it is in the HTML somebody is served depends on
   * how the route renders, and a missing arrow would look exactly like a
   * screen that is fine. So it is asserted here, on the screens as served.
   *
   * Every hub tab this role reaches is checked, not a chosen few - and the two
   * the owner named (Billing → Hours and Communication → Texts) are reported
   * by name, because a check that silently skipped them would still pass.
   */
  /**
   * Whether this screen promises a way back, by the rule the component uses.
   *
   * The first version of this asked two coarser questions - is the path in the
   * navigation, and is the href literally a landing - and both were wrong on
   * the deployment, which is where it was caught:
   *
   *   Purchase requests is the only Billing screen a Job Search person can
   *   open, so for that role it IS the group's first screen, and an arrow
   *   would point at /billing - a screen that role cannot open.
   *
   *   /billing?doc=<id> is the pending-document view, which is the
   *   Authorizations tab with a document picked. No tab means the first tab,
   *   which is the landing, so it shows none.
   *
   * Both are the component behaving correctly. So this asks what the component
   * asks - navFor for this role, currentItemHref for which tab is current -
   * rather than something near it.
   */
  const nav = navFor(role);
  const promisesBack = (path) => {
    const [pathname, query] = path.split("?");
    return hubBack(nav, pathname, new URLSearchParams(query ?? "").get("tab")) !== null;
  };

  const ARROW = /class="sub record-back no-print"/;
  const hubTabs = results.filter((r) => r.ok && promisesBack(r.path));
  for (const r of hubTabs) {
    if (!ARROW.test(r.body ?? "")) {
      results.push({
        path: r.path,
        ok: false,
        why: "no way back off this hub tab - the layout's back arrow is not in the page",
      });
    }
  }
  // ── the Clients tab, and the shadow a restricted document leaves ──
//
// Clients came onto the sidebar for every role on 15 Oct 2026, and the point
// of it is that a team member who is not on a caseload can still open a
// client and read their file. So each role that has an account here opens the
// tab, opens a client, and reads the Documents list.
//
// Then the half that matters more: for a document this person may not open,
// the view is supposed to hand back the row with its name and its type blank.
// That is checked as the real person against the real deployment rather than
// inferred from the page, because a name that is missing from some HTML might
// only be missing from that corner of it.
//
// Each account is optional, the way the Billing one has been since 0129: a
// check that cannot run says so instead of failing.
const CLIENT_ROLES = [
  ["Job Coach", "SMOKE_COACH_EMAIL", "SMOKE_COACH_PASSWORD"],
  ["Case Manager", "SMOKE_CASE_EMAIL", "SMOKE_CASE_PASSWORD"],
  ["Billing", "SMOKE_BILLING_EMAIL", "SMOKE_BILLING_PASSWORD"],
];

const missingAccounts = [];
for (const [role, emailKey, passwordKey] of CLIENT_ROLES) {
  if (!process.env[emailKey] || !process.env[passwordKey]) {
    missingAccounts.push(`${role} (${emailKey})`);
    continue;
  }
  await signIn(process.env[emailKey], process.env[passwordKey], `automated-check (${role.toLowerCase()})`);

  const list = await open("/clients");
  if (!list.ok) {
    all.push({ ...list, role, path: "/clients" });
  } else {
    /**
     * Which client to open.
     *
     * This read the first link on /clients, and for two deploys running that
     * found nothing and said so in a note: the list opens on **Mine**, and
     * an automated-check account is on nobody's caseload. So no record was
     * opened as any role, and the per-role half of this check had quietly
     * stopped running.
     *
     * The list is still the first try, because a client reachable by
     * clicking is the thing being checked. Where it lists nobody, the role
     * asks the database as itself - RLS still answers, so a role that may
     * not read a client still gets nothing - and prefers a client with a
     * Personal note on it, which is the one that makes the dashboard probe
     * below say something.
     */
    let who = (list.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1];
    if (!who) {
      const { data: noted } = await supabase
        .from("notes")
        .select("client_id")
        .eq("category", "Personal")
        .not("client_id", "is", null)
        .limit(1);
      who = noted?.[0]?.client_id;
    }
    if (!who) {
      const { data: anyone } = await supabase.from("clients").select("id").eq("status", "Active").limit(1);
      who = anyone?.[0]?.id;
    }
    if (!who) {
      console.log(`  note  ${role} can read no client at all, so no record was opened`);
    } else {
      const record = await open(`/clients/${who}?tab=documents`);
      all.push({ ...record, role, path: `/clients/<id>?tab=documents` });
      if (record.ok && !/Add a file|No documents yet/.test(record.body)) {
        all.push({
          role,
          path: `/clients/<id>?tab=documents`,
          ok: false,
          why: "the Documents tab opened without the document list or the Add a file form on it",
        });
      } else if (record.ok) {
        console.log(`  ok      ${role.padEnd(12)} opened a client and read their Documents`);
      }

      /**
       * The dashboard is the record's front page now, so what it must never
       * show is asked here as the role, against production.
       *
       * Two rules: a Personal note is read on the Notes tab and nowhere else,
       * and a recording's words never leave the recording.
       *
       * The first version of this asked the database "with the service key",
       * which this script does not have - `supabase` is the anon client
       * signed in as this very role. So for a role that may not read a
       * Personal note the query came back empty and the check congratulated
       * itself on finding nothing. It now says which of the two answers it
       * got, and where a role *can* read the note it asks the question that
       * discriminates: **the same note is on the Notes tab and not on the
       * dashboard.** Absent from both would mean the probe proves nothing.
       */
      const dash = await open(`/clients/${who}?tab=dashboard`);
      all.push({ ...dash, role, path: `/clients/<id>?tab=dashboard` });
      if (dash.ok && !/Where they are/.test(dash.body)) {
        all.push({
          role,
          path: `/clients/<id>?tab=dashboard`,
          ok: false,
          why: "the dashboard opened without its sections on it",
        });
      } else if (dash.ok) {
        const notes = await open(`/clients/${who}?tab=notes`);
        const [{ data: personal }, { data: recorded }] = await Promise.all([
          supabase.from("notes").select("text").eq("client_id", who).eq("category", "Personal").limit(5),
          supabase.from("recordings").select("transcript").eq("client_id", who).not("transcript", "is", null).limit(5),
        ]);
        // A fragment long enough that matching it is not a coincidence, and
        // escaped the way the page would print it.
        const fragment = (s) =>
          typeof s === "string" && s.trim().length >= 24
            ? s.trim().slice(0, 60).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/'/g, "&#x27;")
            : null;

        const personalText = (personal ?? []).map((n) => fragment(n.text)).filter(Boolean);
        const transcripts = (recorded ?? []).map((r) => fragment(r.transcript)).filter(Boolean);

        const onDashboard = [...personalText, ...transcripts].filter((t) => dash.body.includes(t));
        if (onDashboard.length) {
          all.push({
            role,
            path: `/clients/<id>?tab=dashboard`,
            ok: false,
            why: `the dashboard showed ${
              personalText.some((t) => onDashboard.includes(t)) ? "a Personal note" : "a recording's transcript"
            }`,
          });
        } else if (personalText.length) {
          // The control: this role may read the note, so it has to be on the
          // Notes tab. If it is on neither, the rule above was not tested.
          const onNotes = notes.ok && personalText.some((t) => notes.body.includes(t));
          if (!onNotes) {
            all.push({
              role,
              path: `/clients/<id>?tab=notes`,
              ok: false,
              why: "a Personal note this role can read is on neither the dashboard nor the Notes tab, so the dashboard rule was not tested",
            });
          } else {
            console.log(
              `  ok      ${role.padEnd(12)} reads a Personal note on the Notes tab and not on the dashboard`,
            );
          }
        } else {
          console.log(
            `  note  ${role} may read no Personal note on that client, so the dashboard rule was answered by RLS rather than by the stream`,
          );
        }

        if (transcripts.length) {
          console.log(`  ok      ${role.padEnd(12)} opened the dashboard with no transcript on it`);
        } else {
          console.log(`  note  ${role} may read no transcript on that client, so none could have leaked to the dashboard`);
        }
      }
    }
  }

  // What this person is handed for a document they may not open.
  const { data: shadows } = await supabase
    .from("client_documents")
    .select("id, client_id, filename, category, note, storage_path, can_open, restricted")
    .eq("restricted", true)
    .eq("can_open", false)
    .limit(1);

  const shadow = (shadows ?? [])[0];
  if (!shadow) {
    console.log(
      `  note  ${role} has access to every restricted document on file, so the redaction was not exercised for them`,
    );
    continue;
  }

  const leaked = [
    ["name", shadow.filename],
    ["type", shadow.category],
    ["note", shadow.note],
    ["path", shadow.storage_path],
  ].filter(([, value]) => (value ?? "") !== "");

  if (leaked.length) {
    all.push({
      role,
      path: "a restricted document",
      ok: false,
      why: `a restricted document gave up its ${leaked.map(([what]) => what).join(" and ")}`,
    });
  } else {
    console.log(`  ok      ${role.padEnd(12)} sees a restricted document exists and nothing about it`);
  }

  // And the table underneath still refuses them the row entirely.
  const { data: rows } = await supabase.from("attachments").select("id").eq("id", shadow.id);
  if ((rows ?? []).length > 0) {
    all.push({
      role,
      path: "a restricted document",
      ok: false,
      why: "the attachments table handed over a restricted row the view had redacted",
    });
  }
}

if (missingAccounts.length) {
  console.log(
    `  note  no account for ${missingAccounts.join(", ")}, so the Clients tab was not opened as ${missingAccounts.length === 1 ? "that role" : "those roles"}`,
  );
}

for (const named of ["/billing?tab=hours", "/messages/texts?tab=texts"]) {
    const seen = hubTabs.find((r) => r.path === named);
    if (seen) {
      console.log(`  ${role}: ${named} has the way back`);
    } else if (results.some((r) => r.path === named && r.ok)) {
      results.push({
        path: named,
        ok: false,
        why: "opened but not checked for a back arrow - it is a hub landing, or the navigation no longer offers it",
      });
    }
  }
  // Between them the two accounts must have opened both. Said per role, and
  // counted across roles at the end.
  backChecked.push(...hubTabs.map((r) => r.path));

  /**
   * No warrant on anybody's screen but Admin's.
   *
   * The owner's ruling, 14 November 2026: a warrant stub, a warrant line, a
   * voucher number and a warrant total are Admin's, and Billing sees the
   * outcome. The database holds that - the columns are closed and
   * `verify_warrants_are_admins` asks a real Billing session for every one of
   * them - but what the database refuses and what a page prints are two
   * questions, and this is the one nothing else asks: the rendered HTML of
   * every screen this role just opened, read for a number.
   *
   * Shapes rather than the word: "warrant" appears on these screens as
   * provenance ("backfilled from the warrant that paid it"), which is not a
   * warrant.
   *
   * A USOR warrant number is F and eight digits; a voucher is a two-digit
   * year, two letters and a run of digits (26AW00000051141, 26PR00000000701).
   *
   * What this must never match is an **authorization number**, which is V and
   * seven digits - V1028166. The first version of this check matched those,
   * and reported nineteen of the hundred and thirty screens on production for
   * printing the number the practice bills under. An authorization number is
   * on every Billing screen and every client record because that is what it
   * is for. `KNOWN_GOOD` below is the guard against writing that twice.
   */
  if (role !== "Admin") {
    const NUMBER = /\b(F\d{8}|2\d[A-Z]{2}\d{6,})\b/;
    // The shapes a Billing screen is supposed to print: an authorization
    // number, an invoice number, a claim, a client number. If the pattern
    // above ever matches one of these, it is the pattern that is wrong.
    const KNOWN_GOOD = ["V1028166", "V999066", "123456-C", "1070", "2026-11-03"];
    const wrongly = KNOWN_GOOD.filter((g) => NUMBER.test(g));
    if (wrongly.length) {
      results.push({
        path: "the warrant-number pattern in scripts/smoke.mjs",
        ok: false,
        why: `it matches ${wrongly.join(", ")}, which a Billing screen is supposed to print`,
      });
    }
    for (const r of results) {
      if (!r.ok || !r.body) continue;
      const found = NUMBER.exec(r.body);
      if (!found) continue;
      results.push({
        path: `${r.path} (a warrant number on the page)`,
        ok: false,
        why: `the page prints ${found[1]}, which looks like a warrant or voucher number - warrants are Admin's`,
      });
    }
  }

  return { results, client, item, statement };
}

// ── the verdict ───────────────────────────────────────────────
const all = [];
await signIn(env("SMOKE_EMAIL"), env("SMOKE_PASSWORD"), "automated-check");
/**
 * Team, asked for before the sweep rather than after it.
 *
 * It is in the sidebar below the groups rather than in one of them, so the
 * sweep never opens it for this role and it has to be asked for here.
 *
 * It used to be asked for after the pass, and that failed two deploys in a
 * row: pass() ended by signing the account out, so the next line asked for a
 * screen with no session and the middleware sent it to /login. The comment
 * that stood here blamed the age of the session and said so at length. It was
 * wrong - the session was twenty-four seconds old - and the real cause was one
 * line above the request. The sign-out has moved into signIn(), where it
 * cannot get in front of a request, and open() now says when the jar is empty
 * rather than listing three things it might be.
 */
const teamPage = await open("/team");

/**
 * Colleagues, asked early for the same reason Team is (owner, 6 Nov 2026).
 *
 * The sweep walks the navigation, the navigation names /counselors, and
 * /counselors lands on the counselors. So the tab that holds the practice's
 * own numbers is never opened by a pass unless it is opened here.
 *
 * Two things would make it useless and neither shows in a diff: a table that
 * came back with nobody in it, and no way to start a conversation. The
 * Message control is the one that has been wrong before — the Directory's
 * version pointed at an address Team does not read, and did nothing for a
 * week without anybody noticing.
 */
const colleaguesTab = await open("/counselors?tab=colleagues");

/**
 * The phone app (owner, 11 Nov 2026), as the system account.
 *
 * /phone is outside app/(app) - it has its own frame - so the sweep that
 * walks the navigation never opens it, and it is asked for here: the page,
 * and each address it reads from, which must answer with JSON rather than
 * with a server error or a sign-in page.
 *
 * Then the question check-phone.mjs can only ask from the source: does each
 * view fit 375px with no sideways scroll, with real data in it. That needs a
 * browser, and the deploy job installs one; run by hand without one, the
 * check says it did not measure rather than passing quietly.
 */
const phoneChecks = [];
{
  const page = await open("/phone");
  phoneChecks.push({ ...page, path: "/phone", role: "Admin" });
  for (const path of ["/api/phone/home", "/api/phone/clients", "/api/phone/team"]) {
    const r = await open(path);
    let json = null;
    try {
      json = r.ok ? JSON.parse(r.body ?? "") : null;
    } catch {
      json = null;
    }
    phoneChecks.push(
      r.ok && json && !json.error
        ? { path, ok: true, role: "Admin" }
        : { path, ok: false, role: "Admin", why: r.ok ? `answered without its data (${(r.body ?? "").slice(0, 80)})` : r.why },
    );
  }

  let chromium = null;
  try {
    ({ chromium } = await import("playwright"));
  } catch {
    chromium = null;
  }
  if (!chromium) {
    console.log("  NOT MEASURED  /phone at 375px - no browser here; the deploy job installs one");
  } else {
    let browser = null;
    try {
      browser = await chromium.launch();
      const ctx = await browser.newContext({ viewport: { width: 375, height: 812 }, isMobile: true, hasTouch: true });
      const host = new URL(BASE).hostname;
      await ctx.addCookies([...jar].map(([name, value]) => ({ name, value, domain: host, path: "/", secure: true, sameSite: "Lax" })));
      if (BYPASS) await ctx.setExtraHTTPHeaders({ "x-vercel-protection-bypass": BYPASS });
      const tab = await ctx.newPage();
      await tab.goto(`${BASE}/phone`, { waitUntil: "networkidle" });
      for (const hash of ["#/", "#/clients", "#/add", "#/hours", "#/tofile", "#/reports", "#/team", "#/outbox", "#/more"]) {
        await tab.evaluate((h) => {
          window.location.hash = h;
        }, hash);
        await tab.waitForTimeout(1500);
        const w = await tab.evaluate(() => document.documentElement.scrollWidth);
        phoneChecks.push(
          w <= 375
            ? { path: `/phone${hash} at 375px`, ok: true, role: "Admin" }
            : { path: `/phone${hash} at 375px`, ok: false, role: "Admin", why: `${w}px wide - it scrolls sideways on a phone` },
        );
      }
    } catch (err) {
      phoneChecks.push({ path: "/phone at 375px", ok: false, role: "Admin", why: `the browser could not open it: ${err instanceof Error ? err.message : err}` });
    } finally {
      await browser?.close().catch(() => {});
    }
  }
  for (const c of phoneChecks) console.log(`  ${c.ok ? "ok    " : "FAILED"}  ${c.path}${c.ok ? "" : ` - ${c.why}`}`);
  // Counted with every other screen, so a phone screen that fails fails the deploy.
  all.push(...phoneChecks);
}

const jobSearch = await pass("Job Search");
all.push(...jobSearch.results.map((r) => ({ ...r, role: "Job Search" })));

/**
 * The Team bubble is on every screen, and not on the Team page (owner, 5 Nov).
 *
 * Asked of the deployment rather than of the source, because the two ways this
 * breaks are both invisible in a diff: a layout that stops rendering it, and a
 * pathname guard that matches everything. Every screen this role opened is
 * checked, not one of them - the bubble lives in the layout, so "on every
 * screen" is the claim, and one screen passing says nothing about the rest.
 *
 * It is in the server-rendered HTML because a client component still renders
 * once on the server, which is also why this can be a fetch rather than a
 * browser.
 */
{
  const opened = jobSearch.results.filter((r) => r.ok && r.body);
  const without = opened.filter((r) => r.path !== "/team" && !r.body.includes('class="team-bubble'));
  const team = teamPage;
  if (opened.length === 0) {
    all.push({ role: "Job Search", path: "the Team bubble", ok: false, why: "no screen came back with a page to look at" });
  } else if (!team.ok) {
    all.push({ role: "Job Search", path: "/team", ok: false, why: team.why ?? "the Team page did not open" });
  } else if (without.length > 0) {
    all.push({
      role: "Job Search",
      path: "the Team bubble",
      ok: false,
      why: `${without.length} of ${opened.length} screens have no Team bubble, starting with ${without[0].path}`,
    });
  } else if (team.body.includes('class="team-bubble')) {
    all.push({
      role: "Job Search",
      path: "the Team bubble",
      ok: false,
      why: "the bubble is on /team as well, floating over the same conversations",
    });
  } else {
    all.push({ role: "Job Search", path: `the Team bubble on all ${opened.length} screens`, ok: true });
  }
}

/**
 * One thing asked of the page, and it is the claim: somebody on this tab can
 * be messaged.
 *
 * Nothing else on this screen renders the word Message on its own - the six
 * other places in the app that do are all on other screens - so this fails if
 * the tab fell back to the counselors, and it fails if the table came back
 * with nobody in it.
 *
 * It asked for the filter box first, which was a question near the rule rather
 * than the rule: DataTable draws that box only above eight rows, the practice
 * has five people on it, and so a healthy screen failed and rolled production
 * back. Written without having watched it pass, because there was nowhere to
 * watch it pass but the deployment it was about to judge.
 */
{
  const page = colleaguesTab;
  const path = "/counselors?tab=colleagues";
  if (!page.ok) {
    all.push({ role: "Job Search", path, ok: false, why: page.why ?? "the Colleagues tab did not open" });
  } else if (!/>Message\s*</.test(page.body)) {
    all.push({
      role: "Job Search",
      path,
      ok: false,
      why: "nobody on the tab can be messaged - either the counselors came back instead, or the table has nobody in it",
    });
  } else {
    all.push({ role: "Job Search", path, ok: true });
  }
}

// The Billing account is optional: until it exists the check runs as it
// always has, and says which screens nobody is opening (0129).
if (process.env.SMOKE_BILLING_EMAIL && process.env.SMOKE_BILLING_PASSWORD) {
  await signIn(process.env.SMOKE_BILLING_EMAIL, process.env.SMOKE_BILLING_PASSWORD, "automated-check (billing)");
  const billing = await pass("Billing");
  all.push(...billing.results.map((r) => ({ ...r, role: "Billing" })));
  if (!billing.item) {
    // An annotation, not a note: the working list being empty is worth knowing,
    // and so is the link to a record having changed shape again.
    console.log(
      "::warning title=No authorization record opened::" +
        "Nothing on Billing linked to /billing/authorizations/<id>, so the record screen - the checklist, the papers, the submit - was not opened by this run.",
    );
  }
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

/**
 * /**
 * Margaret's role, and the billing actions rather than only the screens.
 *
 * On 19 Oct every billing action returned "Application error: a server-side
 * exception has occurred". Two "use server" files exported a plain object,
 * which React refuses when it first requires the module. This check opened
 * all of those screens that morning and passed, because **opening a screen
 * never loads the action module** - that happens on the POST, which nothing
 * here had ever made.
 *
 * So: every billing screen this role reaches, and then every action on them,
 * submitted the way a browser with no JavaScript submits - the hidden
 * $ACTION_ID the form carries, posted back to the same URL. Each one is sent
 * **empty**, so what comes back is the action's own refusal ("Choose the rows
 * to close.") rather than a change to anybody's record. What is being asserted
 * is only that the module loads and the action answers.
 *
 * Two things keep it safe. The fields are empty, so every action refuses on
 * its own validation; and the account is a system account (0120), so the
 * database refuses it a write even if an action ever stopped validating.
 */
const unescape = (s) =>
  s
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");

/**
 * The forms on a page, as the hidden fields each one would submit.
 *
 * These are `useActionState` forms, so what identifies the action is not one
 * id but the set React puts in the form: `$ACTION_REF_n`, `$ACTION_n:1`
 * carrying the previous state, and `$ACTION_KEY`. A browser with JavaScript
 * turned off posts exactly those, multipart, back to the same URL - so that
 * is what this sends, and nothing else. No user field is filled.
 */
function actionForms(html) {
  const forms = [];
  for (const m of html.matchAll(/<form\b[^>]*>([\s\S]*?)<\/form>/g)) {
    const inner = m[1];
    if (!inner.includes("$ACTION_REF_")) continue;
    const fields = [];
    for (const f of inner.matchAll(/<input[^>]*type="hidden"[^>]*>/g)) {
      const name = f[0].match(/name="([^"]*)"/)?.[1];
      if (!name) continue;
      fields.push([unescape(name), unescape(f[0].match(/value="([^"]*)"/)?.[1] ?? "")]);
    }
    // The inner HTML comes back with the fields (19 Nov 2026), because the
    // hidden names cannot tell two forms apart on a screen where every form
    // carries the same `auth_id` - and the authorization record is nine forms
    // all carrying it, one of which emails a packet to the billing office.
    if (fields.some(([n]) => n.startsWith("$ACTION_REF_"))) forms.push({ fields, inner });
  }
  return forms;
}

/**
 * One form on a page, chosen by a field it carries, posted with fields of our
 * own (the owner's definition of done for parts A and B, 9 November 2026).
 *
 * `invokeActions` posts every form on a screen, which is right where every
 * action refuses an empty submission and wrong where one of them sends a text
 * to a client. Weekly updates has an Approve and a Send all approved on it;
 * posting those blind on every deploy would send real texts to real people.
 *
 * So this picks the one action whose refusal proves the module loads - an
 * empty name, an empty body, no client chosen - and posts nothing else. What
 * is asserted is the same thing: the module loads and the action answers.
 */
async function invokeOne(path, role, what, pick, extra = [], expect = null) {
  const page = await open(path);
  if (!page.ok) return { role, path: `${path} (${what})`, ok: false, why: page.why };

  const forms = actionForms(page.body).filter((f) => pick(f.fields.map(([n]) => n), f.inner));
  if (forms.length === 0) {
    return {
      role,
      path: `${path} (${what})`,
      ok: false,
      why: `no ${what} form on the page - either the screen lost it or it stopped working without JavaScript`,
    };
  }

  const body = new FormData();
  for (const [name, value] of forms[0].fields) body.append(name, value);
  for (const [name, value] of extra) body.set(name, value);
  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    redirect: "manual",
    headers: { cookie: cookie(), ...(BYPASS ? { "x-vercel-protection-bypass": BYPASS } : {}) },
    body,
  });
  remember(res);
  const text = res.status === 204 ? "" : await res.text();
  if (res.status >= 500) {
    return { role, path: `${path} (${what})`, ok: false, why: `HTTP ${res.status} - the action module did not load` };
  }
  const mark = ERROR_MARKS.find((m) => m.test(text));
  if (mark) {
    return {
      role,
      path: `${path} (${what})`,
      ok: false,
      why: `a server error answering the action (${(text.match(mark) ?? [""])[0]})`,
    };
  }
  /*
   * And, where one is given, the answer itself (19 Nov 2026).
   *
   * "It did not throw" is all this could say until now, which is the same
   * thing the screen said while it was writing nothing: the three status
   * writes reported success on a write that changed no rows. So an action
   * whose refusal is the point is posted with what makes it refuse, and the
   * sentence has to come back.
   */
  if (expect && !expect.test(text)) {
    return {
      role,
      path: `${path} (${what})`,
      ok: false,
      why: `the action answered without saying ${expect} - which is what it says when it has done nothing`,
    };
  }
  return { role, path: `${path} (${what})`, ok: true };
}

async function invokeActions(path, role) {
  const page = await open(path);
  if (!page.ok) return [{ role, path, ok: false, why: page.why }];

  const forms = actionForms(page.body);
  if (forms.length === 0) {
    return [
      {
        role,
        path: `${path} (actions)`,
        ok: false,
        why: "no server action on the page - either the screen lost its forms or they stopped working without JavaScript",
      },
    ];
  }

  const out = [];
  for (const [i, form] of forms.entries()) {
    const body = new FormData();
    for (const [name, value] of form.fields) body.append(name, value);
    const res = await fetch(`${BASE}${path}`, {
      method: "POST",
      redirect: "manual",
      headers: { cookie: cookie(), ...(BYPASS ? { "x-vercel-protection-bypass": BYPASS } : {}) },
      body,
    });
    remember(res);
    const text = res.status === 204 ? "" : await res.text();
    const where = `${path} action ${i + 1} of ${forms.length}`;
    if (res.status >= 500) {
      out.push({ role, path: where, ok: false, why: `HTTP ${res.status} - the action module did not load` });
      continue;
    }
    const mark = ERROR_MARKS.find((m) => m.test(text));
    if (mark) {
      out.push({
        role,
        path: where,
        ok: false,
        why: `a server error answering the action (${(text.match(mark) ?? [""])[0]})`,
      });
      continue;
    }
    out.push({ role, path: where, ok: true });
  }
  return out;
}

/**
 * Every control that settles an authorization, pressed as Billing (owner,
 * 19 November 2026).
 *
 * The fault this answers: "Paid", "Record payment" and "Done" appeared to do
 * nothing on Billing. Three of the writes behind those screens were
 * `update(...).eq("id", id)` reporting success on whatever came back - which
 * for PostgREST includes "no error, nothing changed" - so the screen said
 * "Ready to bill" over a record that had not moved. 0375 put all eight through
 * one helper that insists exactly one row changed.
 *
 * Each control is posted with an authorization id that is not on file, which
 * does three things at once: the action module loads, the action answers, and
 * the answer is the refusal rather than the success. Nothing anywhere is
 * written - which is as well, because the account here is a system account and
 * 0120 refuses it every write by design, so that a mistake in a check cannot
 * change anybody's record.
 *
 * Which means this cannot prove a state change, and does not pretend to. That
 * half is `supabase/verify_billing_doors.sql`, which presses the same doors as
 * a Billing person and asks the row afterwards. What would let the deploy
 * itself prove it is a Billing account that is not a system account, and
 * making accounts is the owner's.
 *
 * Two controls are missing from the list below and are missing on purpose. The
 * board's Paid-on cell and its status pill only exist once a client row is
 * expanded, and Mark N paid only once rows are chosen - all three are drawn in
 * the browser, so they are not in the HTML a check without a browser receives.
 * The database door under all of them is `record_payment`, which the record's
 * own Record a payment posts here.
 *
 * And the one form never posted: Submit. It emails the packet to the billing
 * office, and every form on that record carries the same `auth_id`, which is
 * why `actionForms` hands back the inner HTML for a picker to read.
 */
if (process.env.SMOKE_BILLING_EMAIL && process.env.SMOKE_BILLING_PASSWORD) {
  await signIn(
    process.env.SMOKE_BILLING_EMAIL,
    process.env.SMOKE_BILLING_PASSWORD,
    "automated-check (billing actions)",
  );

  // Not on file, and shaped like a uuid so it reaches the database rather than
  // being turned back by a parse error on the way.
  const NOWHERE = "00000000-0000-4000-8000-000000000000";
  const GONE = /is not on your list any more/;
  const UNKNOWN = /That authorization does not exist/;

  const board = await open("/billing");
  if (!board.ok) {
    all.push({ ...board, role: "Billing", path: "/billing (actions)" });
  } else {
    // A settled record offers none of these, so the first link is not
    // necessarily the one to press: Billing › Authorizations groups Paid and
    // Closed on the board too. Open them until one is still being worked.
    const links = [...new Set([...board.body.matchAll(new RegExp(`/billing/authorizations/${uuid}`, "g"))].map((m) => m[0]))];
    let record = null;
    for (const link of links.slice(0, 6)) {
      const page = await open(link);
      if (page.ok && page.body.includes('name="closed_reason"')) {
        record = link;
        break;
      }
    }

    if (!record) {
      console.log(
        `::warning title=No authorization to press::${links.length} authorization record(s) were linked from Billing and none of them offers the controls, so none was pressed on this deploy.`,
      );
    } else {
      /*
       * The two that go through the helper, posted so that nothing matches.
       * This is the assertion the fault report asked for: a write that changed
       * no rows says so, in a sentence, instead of reporting success.
       */
      all.push(
        await invokeOne(
          record,
          "Billing",
          "close, on a record that is not there",
          (names, inner) => inner.includes('name="closed_reason"'),
          [["auth_id", NOWHERE], ["closed_reason", "ZZ smoke: an id that is not on file"]],
          GONE,
        ),
      );
      all.push(
        await invokeOne(
          record,
          "Billing",
          "the service dates, on a record that is not there",
          (names, inner) => inner.includes('name="service_start"'),
          [["auth_id", NOWHERE], ["service_start", "2026-01-01"]],
          GONE,
        ),
      );

      // And the three the database answers for itself.
      all.push(
        await invokeOne(
          record,
          "Billing",
          "record a payment, on a record that is not there",
          (names, inner) => inner.includes('name="received"') && inner.includes('name="amount"'),
          [["auth_id", NOWHERE], ["received", "2026-01-01"], ["amount", "1.00"]],
          UNKNOWN,
        ),
      );
      all.push(
        await invokeOne(
          record,
          "Billing",
          "set the status, on a record that is not there",
          (names, inner) => inner.includes('name="status"'),
          [["auth_id", NOWHERE], ["status", "Due"]],
          UNKNOWN,
        ),
      );
      all.push(
        await invokeOne(
          record,
          "Billing",
          "save the record, on a record that is not there",
          (names, inner) => inner.includes('name="funding_source"'),
          [["auth_id", NOWHERE], ["number", "ZQ-SMOKE"]],
          UNKNOWN,
        ),
      );
    }
  }
} else {
  console.log(
    "  note  no SMOKE_BILLING_EMAIL, so no control that settles an authorization was pressed on this deploy",
  );
}

/**
 * The Reports role: Intake & Client Reports, which is how Margaret reaches
 * billing - by a grant rather than by the role itself. Optional like the
 * others, and loud about it when it is missing, because this is the role the
 * 19 Oct outage was reported on.
 *
 * Not a check account, and not the one 0296 dropped. The actions below are
 * posted, and a system account cannot write to a table - these secrets name
 * somebody with the grant. They have never been set, which is why every
 * deploy says so.
 */
if (process.env.SMOKE_REPORTS_EMAIL && process.env.SMOKE_REPORTS_PASSWORD) {
  await signIn(process.env.SMOKE_REPORTS_EMAIL, process.env.SMOKE_REPORTS_PASSWORD, "automated-check (reports)");
  /**
   * Compose, on a client, with the templates filled in (owner, 23 Oct 2026).
   *
   * Opened rather than posted: posting would send a real email to a real
   * counselor, which is not a thing to do on every deploy. What a GET proves
   * is the part that broke the last time something like this shipped - the
   * screen renders at all, under a role that is not Admin, with its recipient
   * list and its three templates on it. Every one of those comes from a
   * different elevated function, and any of them refusing this role is a
   * blank screen rather than an error.
   */
  // All clients, which is a table of links - the board shows cards whose
  // record link lives in the side panel, so there is no href to read there.
  const zz = await open(`/clients?tab=all&q=${encodeURIComponent(SMOKE_CLIENT)}`);
  const client = zz.ok ? (zz.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1] : null;
  if (!client) {
    /*
     * The fixture is missing, and that is a failure (owner, 24 Oct 2026).
     *
     * The practice carries exactly one permanent client for this -
     * SMOKE_CLIENT, inactive, the single name verify_zz_no_fixtures permits
     * on file. If it is gone, these two steps are not running, and a step
     * that quietly stops running is worse than no step: the Jobs one below
     * is what would have caught Margaret's row-level security bug.
     */
    all.push({
      role: "Reports",
      path: "/mail/compose?client=…",
      ok: false,
      why: zz.ok
        ? `All clients listed no "${SMOKE_CLIENT}" - the practice's one permanent fixture is missing, so Compose is not exercised`
        : `All clients did not open: ${zz.why}`,
    });
  } else {
    const compose = await open(`/mail/compose?client=${client}`);
    if (!compose.ok) {
      all.push({ ...compose, role: "Reports" });
    } else {
      // The three letters, by the names Admin can rename them to - so this
      // reads the picker rather than the words, which are the owner's.
      const hasPicker = /id="mail-template"/.test(compose.body);
      const options = (compose.body.match(/<option value="[a-z_]+"/g) ?? []).length;
      all.push({
        role: "Reports",
        path: `/mail/compose?client=${client}`,
        ok: hasPicker && options >= 3,
        why: hasPicker
          ? options >= 3
            ? undefined
            : `the template list loaded ${options} of the three letters`
          : "Compose opened with no template list, so no template can be chosen",
      });
    }
  }

  /**
   * A job search update, added on a client, as Reports (owner, 23 Oct 2026).
   *
   * Margaret's bug: the panel was offered to five roles and the policy
   * accepted it from two, so three of them got "new row violates row-level
   * security policy for table job_leads" and nothing else. The database half
   * is asserted per role in supabase/verify_job_search_updates.sql, rolled
   * back; this is the other half, against the real deployment, through the
   * screen's own action.
   *
   * It writes, which almost nothing in this file does - three rows, on a ZZ
   * client, and it takes them out again afterwards. A refused insert here is
   * a role that cannot do its job on the next deploy, and that is worth the
   * two seconds and the clean-up.
   */
  const zzClient = await open(`/clients?tab=all&q=${encodeURIComponent(SMOKE_CLIENT)}`);
  const forJobs = zzClient.ok ? (zzClient.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1] : null;
  if (!forJobs) {
    // The same fixture, and the same reason it is a failure: see Compose.
    all.push({
      role: "Reports",
      path: "/clients/…?tab=jobs",
      ok: false,
      why: zzClient.ok
        ? `All clients listed no "${SMOKE_CLIENT}" - the practice's one permanent fixture is missing, so the Jobs panel is not posted`
        : `All clients did not open: ${zzClient.why}`,
    });
  } else {
    const record = await open(`/clients/${forJobs}?tab=jobs`);
    if (!record.ok) {
      all.push({ ...record, role: "Reports" });
    } else {
      // The panel has to be offered before anything can be posted through it.
      const offered = /name="new_employer"|name="title"/.test(record.body);
      all.push({
        role: "Reports",
        path: `/clients/${forJobs}?tab=jobs`,
        ok: offered,
        why: offered ? undefined : "the Jobs tab offers this role no way to add a job search update",
      });

      if (offered) {
        const posted = await invokeActions(`/clients/${forJobs}?tab=jobs`, "Reports");
        // An empty submission is refused by the action's own validation, which
        // is a different answer from the database refusing the row - and it is
        // the database's refusal this is looking for.
        const rls = posted.filter((r) => /row-level security|violates row-level/i.test(String(r.why ?? "")));
        all.push({
          role: "Reports",
          path: `/clients/${forJobs}?tab=jobs actions`,
          ok: rls.length === 0,
          why: rls.length === 0 ? undefined : `the database refused ${rls.length} of them: ${rls[0].why}`,
        });
      }
    }
  }
  /**
   * Only /billing, and deliberately.
   *
   * It is the screen that carried both of the broken modules - the worklist
   * form and the import form - so a POST to it is exactly the request that
   * 500'd. And its actions are the ones that refuse an empty submission by
   * their own validation: no rows chosen, no file chosen.
   *
   * The authorization record is opened by the pass above but its actions are
   * not posted blind. Several of them act on a record, one of them sends a
   * packet to USOR, and this account - unlike the Job Search one - is not a
   * system account, because a system account can only be Job Search. An
   * empty submission ought to be refused by each of them; "ought to" is not
   * the standard for a thing that runs unattended on every deploy against
   * production.
   */
  all.push(...(await invokeActions("/billing", "Reports")));
  /**
   * And My day, which has had server actions since the "To file" inbox
   * (0317): assign, confirm, discard.
   *
   * The owner's definition of done for that item asks that the smoke check
   * post a Confirm. Posted the way everything here is posted - empty, as a
   * system account the database refuses writes to - so what comes back is
   * "Choose the client it was about" rather than a contact-log entry on
   * somebody's record. What is asserted is that the module loads and the
   * action answers, which is the whole lesson of 19 October.
   *
   * It reports nothing when the inbox is empty: there are no forms on the
   * screen then, and an inbox nobody has anything waiting in is the ordinary
   * state rather than a fault.
   */
  const myDay = await invokeActions("/my-day", "Reports");
  if (!myDay.some((r) => r.why?.includes("no server action on the page"))) {
    all.push(...myDay);
  }

  /**
   * Three more actions, from the owner's definition of done for 9 November:
   * a contact, a draft approval, and an Assign to client.
   *
   * Each is posted with the one field that makes it refuse - no name, no
   * wording, no client - so the deploy exercises the module and changes
   * nothing. Blind-posting the weekly-updates screen would send real texts,
   * which is why `invokeOne` exists.
   */
  if (forJobs) {
    all.push(
      await invokeOne(
        `/clients/${forJobs}?tab=profile`,
        "Reports",
        "add a contact",
        (names) => names.includes("id"),
        [["name", ""], ["relationship", ""]],
      ),
    );
  }

  const updates = await open("/messages/weekly-updates");
  if (updates.ok && /name="body"/.test(updates.body)) {
    all.push(
      await invokeOne(
        "/messages/weekly-updates",
        "Reports",
        "a draft, reworded",
        (names) => names.includes("id"),
        [["body", ""]],
      ),
    );
  } else if (!updates.ok) {
    all.push({ ...updates, role: "Reports" });
  }
  // Nothing drafted is the ordinary state on five days out of seven, so an
  // empty screen is not a fault - but the screen itself has to open.

  const inbox = await open("/admin/documents");
  if (inbox.ok && /name="document_id"/.test(inbox.body)) {
    all.push(
      await invokeOne(
        "/admin/documents",
        "Reports",
        "assign a document to a client",
        (names) => names.includes("document_id"),
        [["client_id", ""]],
      ),
    );
  } else if (!inbox.ok) {
    all.push({ ...inbox, role: "Reports" });
  }

  /**
   * The reports board, as the person whose board it is (0377, Part 4).
   *
   * Two things a 200 does not prove, and both of them are how this screen
   * would fail quietly. The board's rows come from `report_board_rows`, a
   * SECURITY DEFINER function gated on `is_active_staff()`: a grant that went
   * missing is an empty table under a header, not an error. And the To file
   * panel above it is everybody's for this role and each person's own for
   * everybody else, which is one component reading two filters - the sort of
   * thing that renders fine and shows the wrong inbox.
   *
   * So: the board is asked to have drawn its own table, and the panel is
   * asked to have been drawn with somebody else's name on it, which is only
   * true of this role.
   */
  const board = await open("/client-reports");
  if (!board.ok) {
    all.push({ ...board, role: "Reports" });
  } else {
    const drewTable = /class="board"/.test(board.body);
    const drewGroups = /Not started/.test(board.body);
    all.push({
      role: "Reports",
      path: "/client-reports",
      ok: drewTable && drewGroups,
      why: drewTable
        ? drewGroups
          ? undefined
          : "the board drew a table with no groups in it, so report_board_rows answered nothing"
        : "the board opened without its table, so the rows did not arrive",
    });
  }

  /**
   * And the filing action, pressed on the board.
   *
   * Posted the way everything here is posted - with the one field that makes
   * it refuse - so the deploy exercises the module and writes nothing. What
   * it proves is the lesson of 19 October: the action module loads and
   * answers under this role, on this screen, on this deployment.
   *
   * The other half of the owner's definition of done - that filing attaches
   * the item to the client's month - cannot be proved from here, because
   * nothing a smoke run can do creates a `to_file` item: the table has no
   * insert policy and the two sweeps that fill it are the cron's. It is
   * proved instead in supabase/verify_reports_board.sql, which files a real
   * item as this role and asserts the contact-log entry it writes, dated the
   * day the appointment happened rather than the day it was filed - inside a
   * transaction that is rolled back.
   */
  const boardFiling = await invokeActions("/client-reports", "Reports");
  if (!boardFiling.some((r) => r.why?.includes("no server action on the page"))) {
    all.push(...boardFiling);
  }

  const reports = await pass("Reports");
  all.push(...reports.results.map((r) => ({ ...r, role: "Reports" })));

} else {
  console.log("  note  no SMOKE_REPORTS_EMAIL, so no billing action was exercised as the role the 19 Oct outage was reported on");
  console.log(
    "::warning title=Billing actions unexercised::" +
      "SMOKE_REPORTS_EMAIL and SMOKE_REPORTS_PASSWORD are not set, so no billing action is submitted on any deploy. " +
      "That is the gap the 19 Oct outage went through.",
  );
}

/**
 * Back to the main account for the board.
 *
 * Here rather than higher up the file because this block posts an action, and
 * posting one needs `actionForms`, which reads a `const` declared further
 * down. Put above it, the call threw "Cannot access 'unescape' before
 * initialization" and took the whole run with it - a function declaration is
 * hoisted and a const it closes over is not. Whoever signed in last was
 * Billing or Reports, so the account is set again rather than assumed.
 */
await signIn(env("SMOKE_EMAIL"), env("SMOKE_PASSWORD"), "automated-check");

/**
 * The client threads board, and the one thing a deploy must not do (ruling 7,
 * 23 November 2026).
 *
 * **No automated sends.** Nothing here posts the send form, and that is not
 * caution about the code - it is the rule: a deploy check that presses Send
 * texts a real client every time anybody pushes. The owner presses one real
 * Send by hand after a release that touches sending, and the refusals are
 * proved where they can be proved without a carrier: the consent gate, the
 * STOP gate and the 8am-to-9pm window are in verify_sms.sql, and a reply on
 * any channel, the groups and who may write are in verify_the_threads_board.
 *
 * What this asks of the deployment is the half those cannot reach: that the
 * board draws its own table, that a thread opens, and that the box which does
 * send says which number it would send to before anybody types - because the
 * number is the thing this screen gets wrong if it gets anything wrong. A
 * client, their partner and their daughter-in-law are three numbers on one
 * record and two of them may not be textable.
 */
const threads = await open("/communication/threads");
if (!threads.ok) {
  all.push({ ...threads, role: "Job Search" });
} else {
  const drewTable = /class="board"/.test(threads.body);
  const drewGroups = /Needs a reply/.test(threads.body);
  all.push({
    role: "Job Search",
    path: "/communication/threads",
    ok: drewTable && drewGroups,
    why: drewTable
      ? drewGroups
        ? undefined
        : "the board drew a table with no groups in it, so client_threads_board answered nothing"
      : "the board opened without its table, so the rows did not arrive",
  });

  // A thread, opened the way a person opens one: off the board's own link.
  const openHref = threads.body.match(/href="\/communication\/threads\?c=([0-9a-f-]{36})"/)?.[0];
  if (!openHref) {
    console.log(
      "::warning title=No thread opened::" +
        "No row on the client threads board offered a link to a thread, so the panel - the stream, the reply box and the consent line - was not opened by this run.",
    );
  } else {
    const panel = await open(openHref.match(/href="([^"]+)"/)[1]);
    if (!panel.ok) {
      all.push({ ...panel, role: "Job Search" });
    } else {
      /**
       * The reply box says which number, and when that number agreed.
       *
       * Either it offers a send box naming the number, or it says why it
       * cannot send to any of them. What must never happen is a box with no
       * number named: that is the version of this screen that sends a client's
       * business to their ex-partner's phone.
       */
      const names = /Text .*at \+1\d{10}/.test(panel.body) || /agreed \d{4}-\d{2}-\d{2}/.test(panel.body);
      const refuses =
        /has not agreed to be texted/.test(panel.body) ||
        /replied STOP/.test(panel.body) ||
        /no number on this record/.test(panel.body) ||
        /does not send texts/.test(panel.body);
      all.push({
        role: "Job Search",
        path: "a client thread",
        ok: names || refuses,
        why: "the panel offered a reply box without saying which number it would send to",
      });
      // And the stream came with it.
      all.push({
        role: "Job Search",
        path: "a client thread (the stream)",
        ok: /class="chip">Text</.test(panel.body) || /Nothing on this channel yet/.test(panel.body),
        why: "the thread opened with neither a message in it nor a sentence saying there are none",
      });
    }
  }
}

/**
 * Log a call: the module loads and refuses an empty one.
 *
 * Posted with nothing in it, which is what makes it refuse - the same way
 * every other action on this check is exercised. It writes nothing, and what
 * it proves is that the function behind the one new write on this screen is
 * there on this deployment.
 */
const callForm = await invokeOne(
  "/communication/threads",
  "Job Search",
  "log a call",
  (names) => names.includes("client_id") && names.includes("text"),
  [["text", ""]],
);
if (!callForm.why?.includes("no log a call form on the page")) {
  all.push(callForm);
} else {
  console.log(
    "::note title=No call form::" +
      "No thread was open on the board, so Log a call was not posted. The board's own link is followed above.",
  );
}

/**
 * And the two roles ruling 6c is about are opened by nobody.
 *
 * A Job Coach and a Case Manager can write on a client's record and cannot
 * text, which is the whole reason the send box is gated and Log a call is
 * offered instead. Neither has an account here, so neither half is opened on
 * any deploy. Said as a warning rather than a failure: it is true of every
 * run until somebody makes the accounts.
 */
if (!process.env.SMOKE_COACH_EMAIL && !process.env.SMOKE_CASE_EMAIL) {
  console.log(
    "::warning title=The roles that cannot text are unopened::" +
      "No SMOKE_COACH_EMAIL or SMOKE_CASE_EMAIL, so nothing checks that a Job Coach or a Case Manager is offered Log a call instead of a send box. The database half is in verify_the_threads_board.sql.",
  );
}

/**
 * A Job Search user moves a card, and the contact log shows it (0223).
 *
 * The board's rules are asserted in verify_the_clients_board, rolled back
 * against the real database. This is the other half: the action as a person
 * uses it, against the real deployment, by somebody whose role is the one
 * least likely to be allowed - everybody who can see Clients can move a card,
 * and Job Search is the plainest everybody.
 *
 * It needs an account that can write, so it is not the usual SMOKE_EMAIL: that
 * one is a system account and the database refuses its writes by design
 * (0120), which is what makes the rest of this check safe to run unattended.
 *
 * The fixture is one permanent ZZ client, left Inactive so it never appears
 * on the board or in an active list, moved between Intake and Assessment and
 * back on alternate deploys. One row, not one per deploy.
 */
if (process.env.SMOKE_MOVE_EMAIL && process.env.SMOKE_MOVE_PASSWORD) {
  await signIn(process.env.SMOKE_MOVE_EMAIL, process.env.SMOKE_MOVE_PASSWORD, "automated-check (move)");

  const { data: fixture } = await supabase
    .from("clients")
    .select("id, name, stage, status")
    .eq("name", "ZZ Smoke Board")
    .maybeSingle();

  if (!fixture) {
    console.log("  note  no ZZ Smoke Board client, so no card was moved");
    console.log(
      "::warning title=No board fixture::" +
        "Create an inactive client named \"ZZ Smoke Board\" for the deploy check to move between Intake and Assessment.",
    );
  } else {
    const to = fixture.stage === "Intake" ? "Assessment" : "Intake";
    const note = `Deploy check moved them to ${to}.`;
    const { error: moveError } = await supabase.rpc("move_client", {
      p_client: fixture.id,
      p_stage: to,
      p_note: note,
      p_document: null,
    });

    if (moveError) {
      all.push({ role: "Job Search", path: "move a card", ok: false, why: moveError.message });
    } else {
      const { data: after } = await supabase
        .from("clients")
        .select("stage")
        .eq("id", fixture.id)
        .maybeSingle();
      all.push({
        role: "Job Search",
        path: `move a card to ${to}`,
        ok: after?.stage === to,
        why: `the card is in ${after?.stage ?? "nowhere"}, not ${to}`,
      });

      // The move has to read in the client's own log, which is the half a
      // person actually sees.
      const { data: logged } = await supabase
        .from("contact_log")
        .select("method, topic, outcome")
        .eq("client_id", fixture.id)
        .eq("method", "Stage change")
        .order("date", { ascending: false })
        .limit(1);
      const line = (logged ?? [])[0];
      all.push({
        role: "Job Search",
        path: "the move in the contact log",
        ok: Boolean(line) && line.outcome === note && line.topic.endsWith(to),
        why: line
          ? `the log says "${line.topic}" / "${line.outcome}"`
          : "nothing was written to the contact log",
      });
    }

    // A move with no note is refused, from the outside as well as from SQL.
    const { error: refused } = await supabase.rpc("move_client", {
      p_client: fixture.id,
      p_stage: fixture.stage === "Intake" ? "Job Search" : "Intake",
      p_note: "",
      p_document: null,
    });
    all.push({
      role: "Job Search",
      path: "a move with no note",
      ok: Boolean(refused),
      why: "a move with no note went through",
    });
  }

  await supabase.auth.signOut().catch(() => {});
} else {
  console.log("  note  no SMOKE_MOVE_EMAIL, so no card was moved on this deploy");
  console.log(
    "::warning title=No card was moved::" +
      "SMOKE_MOVE_EMAIL and SMOKE_MOVE_PASSWORD are not set, so the board's move is not exercised by a person on any deploy.",
  );
}

/**
 * And the half of the board no account can reach.
 *
 * Approve, Decline and the sixth tile on Clients › Board are Admin's, and no
 * system account may be Admin (0295), so nothing here opens them on any
 * deploy - the database half is covered by `verify_stage_requests.sql` and the
 * screen half is the owner's to open by hand (owner, 18 Nov 2026, and it is in
 * the definition of done in CLAUDE.md).
 *
 * A note rather than a warning. It is true of every run and will be until
 * somebody decides an automated account may be Admin, and a warning that is
 * always there is a warning nobody reads.
 */
console.log(
  "  note  Approve, Decline and the requests tile on Clients › Board are Admin's, " +
    "so no account here opens them - they are checked by hand",
);

/**
 * And the two screens the owner named were actually reached by somebody.
 *
 * Billing → Hours needs the Billing account and Communication → Texts does
 * not, so neither pass can confirm both. Said across the passes, and a
 * warning rather than a failure when the Billing account is not configured -
 * the run already says, loudly, which screens nobody opened.
 */
for (const named of ["/billing?tab=hours", "/messages/texts?tab=texts"]) {
  if (backChecked.includes(named)) continue;
  const line = `${named} was not opened by any account, so its way back is unconfirmed`;
  if (named.startsWith("/billing") && !process.env.SMOKE_BILLING_EMAIL) {
    console.log(`::warning title=Back arrow unconfirmed::${line}`);
  } else {
    all.push({ ok: false, role: "all", path: named, why: "its way back was never checked" });
  }
}
console.log(`  the way back was asserted on ${backChecked.length} hub tab(s)`);

const failed = all.filter((r) => !r.ok);
/**
 * A screen that failed once and opened on the second look is marked in the
 * list as well as counted at the end. It passed - the run is green on it, by
 * the rule - and "ok" on the same line as every other screen is how a screen
 * that does this every week goes unnoticed for a month.
 */
for (const r of all) {
  const mark = r.ok ? (r.flakyWhy ? "flaky " : "ok    ") : "FAILED";
  const tail = r.ok ? (r.flakyWhy ? `  - ${r.flakyWhy}, then opened` : "") : `  - ${r.why}`;
  console.log(`  ${mark}  ${r.role.padEnd(10)} ${r.path}${tail}`);
}
console.log("");
if (!jobSearch.client) console.log("  note  no client record was listed, so no record tabs were opened");
// Last, so the step summary's `tail -60` of this log carries it.
for (const line of retry.lines()) console.log(line);
if (failed.length) {
  console.error(`${failed.length} of ${all.length} screens failed on ${BASE}.`);
  process.exit(1);
}
console.log(
  `--- ALL ${all.length} SCREENS OPENED WITHOUT A SERVER ERROR (${BASE}) ---` +
    (retry.flaky.length ? ` - ${retry.flaky.length} of them only on the second look` : ""),
);
