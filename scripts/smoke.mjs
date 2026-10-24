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

async function signIn(email, password, who) {
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

async function open(path) {
  let url = `${BASE}${path}`;
  for (let hop = 0; hop < 6; hop++) {
    const res = await fetch(url, {
      redirect: "manual",
      headers: { cookie: cookie(), ...(BYPASS ? { "x-vercel-protection-bypass": BYPASS } : {}) },
    });
    // Before anything is decided about the response: a refreshed session
    // arrives as Set-Cookie on a redirect just as often as on a page.
    remember(res);
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
      if (followed.has(href) || /^\/(login|logout|api)/.test(href)) continue;
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
    const who = (list.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1];
    if (!who) {
      console.log(`  note  ${role} opened /clients and it listed nobody, so no record was opened`);
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
    if (fields.some(([n]) => n.startsWith("$ACTION_REF_"))) forms.push(fields);
  }
  return forms;
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
  for (const [i, fields] of forms.entries()) {
    const body = new FormData();
    for (const [name, value] of fields) body.append(name, value);
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
 * The Reports role: Intake & Client Reports, which is how Margaret reaches
 * billing - by a grant rather than by the role itself. Optional like the
 * others, and loud about it when it is missing, because this is the role the
 * 19 Oct outage was reported on.
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
  const zz = await open("/clients?tab=all&q=ZZ");
  const client = zz.ok ? (zz.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1] : null;
  if (!client) {
    /*
     * No ZZ client on file, so Compose cannot be opened about one.
     *
     * A warning rather than a failure, which is how this file treats every
     * other piece of coverage it cannot run. The two rules behind it pull
     * against each other and the owner has the casting vote:
     * supabase/verify_zz_no_fixtures.sql asserts that nothing ZZ-shaped is
     * left on the database, and this step needs exactly such a row to exist
     * permanently. A failing deploy is the wrong way to ask that question
     * (24 Oct 2026).
     */
    if (!zz.ok) {
      all.push({ role: "Reports", path: "/clients?tab=all", ok: false, why: zz.why });
    } else {
      console.log("  note  no ZZ client on file, so Compose was not opened about one");
      console.log(
        "::warning title=Compose unexercised::" +
          "No ZZ client exists, so Compose on a client and its template list are not opened on any deploy. " +
          "A permanent inactive ZZ client would need an exception in verify_zz_no_fixtures.",
      );
    }
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
  const zzClient = await open("/clients?tab=all&q=ZZ");
  const forJobs = zzClient.ok ? (zzClient.body.match(/\/clients\/([0-9a-f-]{36})/) ?? [])[1] : null;
  if (!forJobs) {
    // The same gap, and the same reason it is a warning: see Compose above.
    if (!zzClient.ok) {
      all.push({ role: "Reports", path: "/clients?tab=all", ok: false, why: zzClient.why });
    } else {
      console.log("  note  no ZZ client on file, so no job search update was added");
      console.log(
        "::warning title=Job search updates unexercised::" +
          "No ZZ client exists, so the Jobs panel is not posted as Reports on any deploy. " +
          "That is the gap Margaret's row-level security bug went through.",
      );
    }
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
for (const r of all) console.log(`  ${r.ok ? "ok    " : "FAILED"}  ${r.role.padEnd(10)} ${r.path}${r.ok ? "" : `  - ${r.why}`}`);
console.log("");
if (!jobSearch.client) console.log("  note  no client record was listed, so no record tabs were opened");
if (failed.length) {
  console.error(`${failed.length} of ${all.length} screens failed on ${BASE}.`);
  process.exit(1);
}
console.log(`--- ALL ${all.length} SCREENS OPENED WITHOUT A SERVER ERROR (${BASE}) ---`);
