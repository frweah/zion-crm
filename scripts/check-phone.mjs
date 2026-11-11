/**
 * The phone app, held to what it promised (owner, 11 Nov 2026).
 *
 *   node scripts/check-phone.mjs     (also runs before every build)
 *
 * "Prebuild check that every phone screen fits 375px with no sideways
 * scroll." A build has no browser, so this cannot measure a screen; it reads
 * what decides whether one can be wider than the phone, which is the
 * stylesheet and the markup, and refuses the things that make a column
 * wider than 343px (375 less two 16px sides):
 *
 *   a width, min-width or flex-basis over 343px, in the phone's CSS or in a
 *   style written on an element;
 *   a grid of fixed columns adding up to more than that;
 *   white-space: nowrap on anything not allowed to end in an ellipsis;
 *   a table or a <pre>, which size themselves to their widest line;
 *   and a frame that does not let a long word break.
 *
 * The measuring is scripts/smoke.mjs, on the deploy, at a 375px viewport, as
 * the system account - which is the question this one is near, asked for
 * real. Both, because the CLAUDE.md lesson is that a check asking a question
 * merely near the rule passes the bug it was written for.
 *
 * And the rest of what makes it an app rather than a page:
 *
 *   The manifest opens /phone, standalone, with icons that exist at the sizes
 *   it says, in the colours tokens.css has.
 *   The phone and the desk apply the sign-in gates through one function, and
 *   that function still requires the second factor where the desk did.
 *   Every /api/phone address asks who is calling, through the same gates.
 *   The service worker keeps only the phone screen and the build's own
 *   files - never an API answer, never another screen.
 *   Every kind the phone saves is a kind the sync address knows.
 */
import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";
import { gateFor } from "../lib/gates.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const PHONE = "app/(phone)";
const LIMIT = 343;

const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    return statSync(full).isDirectory() ? walk(full) : [full];
  });

const files = walk(PHONE);
const css = files.filter((f) => f.endsWith(".css"));
const tsx = files.filter((f) => f.endsWith(".tsx"));

if (css.length === 0 || tsx.length === 0) fail(`${PHONE} has no screens or no stylesheet to check`);

// ── 375px ────────────────────────────────────────────────────
let rules = 0;
for (const file of css) {
  const src = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "");
  for (const m of src.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    rules++;
    const selector = m[1].trim();
    const body = m[2];
    for (const d of body.matchAll(/(?:^|;)\s*(width|min-width|flex-basis)\s*:\s*([\d.]+)px/g)) {
      if (Number(d[2]) > LIMIT) fail(`${file}: ${selector} sets ${d[1]}: ${d[2]}px, wider than a phone's ${LIMIT}px column`);
    }
    for (const d of body.matchAll(/(?:^|;)\s*flex\s*:\s*[\d.]+\s+[\d.]+\s+([\d.]+)px/g)) {
      if (Number(d[1]) > LIMIT) fail(`${file}: ${selector} has a flex basis of ${d[1]}px`);
    }
    for (const d of body.matchAll(/grid-template-columns\s*:\s*([^;]+)/g)) {
      const fixed = [...d[1].matchAll(/([\d.]+)px/g)].reduce((n, x) => n + Number(x[1]), 0);
      if (fixed > LIMIT) fail(`${file}: ${selector} lays out ${fixed}px of fixed columns`);
    }
    if (/white-space\s*:\s*nowrap/.test(body) && !(/text-overflow\s*:\s*ellipsis/.test(body) && /overflow\s*:\s*hidden/.test(body))) {
      fail(`${file}: ${selector} will not wrap and is not allowed to end in an ellipsis, so a long line pushes the screen sideways`);
    }
    if (/overflow-x\s*:\s*(hidden|clip)/.test(body)) {
      fail(`${file}: ${selector} hides what is too wide instead of not being too wide`);
    }
  }
}
const frame = css.map((f) => readFileSync(f, "utf8")).join("\n").match(/\.phone-frame\s*\{([^}]*)\}/);
if (!frame || !/overflow-wrap\s*:\s*anywhere/.test(frame[1])) {
  fail(".phone-frame does not let a long word break, so an email address or a URL can push the screen sideways");
}

for (const file of tsx) {
  const src = readFileSync(file, "utf8");
  if (/<table\b/.test(src)) fail(`${file} draws a table, which is as wide as its widest row`);
  if (/<pre\b/.test(src)) fail(`${file} draws a <pre>, which does not wrap`);
  for (const m of src.matchAll(/\b(width|minWidth|flexBasis)\s*:\s*(\d+)/g)) {
    if (Number(m[2]) > LIMIT) fail(`${file} sets ${m[1]}: ${m[2]} on an element, wider than a phone`);
  }
  if (/style=\{\{[^}]*whiteSpace\s*:\s*["']nowrap/.test(src)) fail(`${file} sets white-space: nowrap on an element`);
}
if (problems.length === 0) ok(`every phone screen fits ${LIMIT + 32}px: ${rules} rules in ${css.length} stylesheet(s), ${tsx.length} screen file(s)`);

// ── the manifest ─────────────────────────────────────────────
const manifest = JSON.parse(readFileSync("public/manifest.webmanifest", "utf8"));
const tokens = readFileSync("app/tokens.css", "utf8");
const lightToken = (name) => tokens.match(new RegExp(`:root\\s*\\{[\\s\\S]*?--${name}:\\s*(#[0-9a-fA-F]{3,8})`))?.[1]?.toLowerCase();

if (manifest.start_url !== "/phone") fail(`the manifest opens ${manifest.start_url}, not /phone`);
if (!existsSync(join(PHONE, "phone", "page.tsx"))) fail("the manifest opens /phone and there is no /phone page");
if (manifest.display !== "standalone" && manifest.display !== "fullscreen") fail(`the manifest opens in "${manifest.display}", inside the browser`);
if (manifest.theme_color?.toLowerCase() !== lightToken("side-bg")) fail(`the manifest's theme colour ${manifest.theme_color} is not --side-bg (${lightToken("side-bg")})`);
if (manifest.background_color?.toLowerCase() !== lightToken("paper")) fail(`the manifest's background ${manifest.background_color} is not --paper (${lightToken("paper")})`);

const pngSize = (path) => {
  const b = readFileSync(path);
  return `${b.readUInt32BE(16)}x${b.readUInt32BE(20)}`;
};
const sizes = new Set();
for (const icon of manifest.icons ?? []) {
  const path = join("public", icon.src);
  if (!existsSync(path)) {
    fail(`the manifest names ${icon.src}, which is not there`);
    continue;
  }
  const real = pngSize(path);
  if (real !== icon.sizes) fail(`${icon.src} says ${icon.sizes} and is ${real}`);
  sizes.add(`${icon.sizes}:${icon.purpose ?? "any"}`);
}
if (!sizes.has("192x192:any") || !sizes.has("512x512:any")) fail("an installable app needs a 192 and a 512 icon");
if (problems.length === 0) ok("the manifest opens /phone, full-screen, with icons that exist, in the theme's colours");

// ── one set of gates ─────────────────────────────────────────
const cases = [
  [{ pathname: "/phone", isSystem: false, onboardingOpen: false, policyDue: false, twoFactor: { required: true, enrolled: true }, authLevel: "aal1" }, "/security/two-factor", "a password-only session where a second factor is required"],
  [{ pathname: "/phone", isSystem: false, onboardingOpen: false, policyDue: false, twoFactor: { required: true, enrolled: false }, authLevel: "aal1" }, "/security/two-factor", "no second factor set up where one is required"],
  [{ pathname: "/phone", isSystem: false, onboardingOpen: false, policyDue: false, twoFactor: { required: true, enrolled: true }, authLevel: "aal2" }, null, "a session that used its second factor"],
  [{ pathname: "/phone", isSystem: false, onboardingOpen: true, policyDue: true, twoFactor: { required: true, enrolled: false }, authLevel: "aal1" }, "/paperwork/onboarding", "somebody still onboarding"],
  [{ pathname: "/phone", isSystem: false, onboardingOpen: false, policyDue: true, twoFactor: null, authLevel: "aal1" }, "/paperwork/policy", "a policy not yet signed"],
  [{ pathname: "/paperwork/policy", isSystem: false, onboardingOpen: false, policyDue: true, twoFactor: null, authLevel: "aal1" }, null, "the policy screen itself"],
  [{ pathname: "/phone", isSystem: true, onboardingOpen: true, policyDue: true, twoFactor: { required: true, enrolled: false }, authLevel: "aal1" }, null, "the system account"],
];
for (const [facts, want, what] of cases) {
  const got = gateFor(facts);
  if (got !== want) fail(`gateFor sends ${what} to ${got ?? "nowhere"}, not ${want ?? "nowhere"}`);
}
const deskLayout = readFileSync("app/(app)/layout.tsx", "utf8");
const phoneLayout = readFileSync(join(PHONE, "phone", "layout.tsx"), "utf8");
for (const [name, src] of [["app/(app)/layout.tsx", deskLayout], ["the phone layout", phoneLayout]]) {
  if (!/gateFor\(/.test(src)) fail(`${name} does not apply the gates through lib/gates.ts`);
}
if (/redirect\(["']\/security\/two-factor["']\)/.test(deskLayout)) {
  fail("app/(app)/layout.tsx has its own second-factor redirect again - two copies of the rule");
}

const apiDir = "app/api/phone";
const routes = walk(apiDir).filter((f) => f.endsWith("route.ts"));
if (routes.length === 0) fail("there are no /api/phone addresses to check");
for (const r of routes) {
  if (!/await phoneStaff\(\)/.test(readFileSync(r, "utf8"))) fail(`${r} answers without asking who is calling through phoneStaff()`);
}
const server = readFileSync("lib/phone/server.ts", "utf8");
if (!/gateFor\(/.test(server)) fail("lib/phone/server.ts does not apply the gates");
if (problems.length === 0) ok(`one set of gates, on the desk, the phone and all ${routes.length} /api/phone addresses (${cases.length} cases)`);

// ── the worker keeps only what it should ─────────────────────
const sw = readFileSync("public/sw.js", "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
if (/["'`]\/api/.test(sw)) fail("public/sw.js mentions /api - an API answer is never the worker's to keep");
const kept = [...sw.matchAll(/startsWith\(["'`]([^"'`]+)["'`]\)/g)].map((m) => m[1]);
const allowed = new Set(["/_next/static/", "/icons/", "zion-phone-"]);
for (const k of kept) if (!allowed.has(k)) fail(`public/sw.js keeps ${k}, which is not the phone screen or the build's own files`);
if (!/res\.redirected/.test(sw)) fail("public/sw.js could keep the sign-in page as the phone screen");
if (problems.length === 0) ok("the service worker keeps the phone screen and the build's files, and nothing else");

// ── every kind the phone saves, the sync address knows ───────
const store = readFileSync("lib/phone/store.ts", "utf8");
const kinds = store.match(/export type OutboxKind = ([^;]+);/)?.[1].match(/"([a-z]+)"/g)?.map((s) => s.replaceAll('"', "")) ?? [];
const sync = readFileSync("app/api/phone/sync/route.ts", "utf8");
if (kinds.length === 0) fail("lib/phone/store.ts no longer says what kinds the phone saves");
for (const k of kinds) {
  if (!new RegExp(`item\\.kind === "${k}"`).test(sync)) fail(`the phone saves "${k}" and the sync address does not know it, so it would be refused for ever`);
}
if (problems.length === 0) ok(`the sync address knows all ${kinds.length} kinds the phone saves (${kinds.join(", ")})`);

if (problems.length > 0) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}
console.log("");
console.log("--- PHONE VERIFIED ---");
