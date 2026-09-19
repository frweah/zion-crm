/**
 * The theme, checked.
 *
 *   node scripts/check-theme.mjs        (also runs before every `npm run build`)
 *
 * Two rules from the design brief, both of which drift quietly:
 *
 *   One token file. A colour written anywhere but app/tokens.css is a colour
 *   the next restyle misses. So any hex value, or rgb()/hsl() in a stylesheet
 *   or a component, outside that file fails.
 *
 *   Contrast. Every token pair the stylesheet uses for text must reach 4.5:1,
 *   and a control's edge or the focus ring 3:1 (WCAG 2.2 AA). Change a value
 *   in tokens.css and this says whether the interface still reads.
 *
 * Fonts are self-hosted: a stylesheet importing a font service also fails.
 *
 * And from the design refresh (v2, 19 Sept 2026):
 *
 *   One type scale. The sizes are --text-* in tokens.css, smallest to
 *   largest; a font size written anywhere else - a px value in a stylesheet,
 *   a number in a component's style - fails.
 *
 *   One motion. A transition or animation uses var(--motion), 200ms
 *   ease-in-out, and names no duration of its own.
 *
 *   Text is never faded: no opacity below 1. No glass: no backdrop-filter,
 *   and the one translucent token (--scrim) is never a border. No dark mode.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const TOKENS = path.join(root, "app", "tokens.css");

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

// ── one token file ───────────────────────────────────────────
const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (name === "node_modules" || name.startsWith(".")) return [];
    return statSync(full).isDirectory() ? walk(full) : [full];
  });

const HEX = /#[0-9a-fA-F]{3}(?:[0-9a-fA-F]{3})?(?:[0-9a-fA-F]{2})?\b/g;
const FUNC = /\b(?:rgba?|hsla?)\(/g;

const sources = ["app", "lib"]
  .flatMap((d) => walk(path.join(root, d)))
  .filter((f) => /\.(css|tsx|ts|mjs)$/.test(f) && path.resolve(f) !== path.resolve(TOKENS));

let offenders = 0;
for (const file of sources) {
  const lines = readFileSync(file, "utf8").split(/\r?\n/);
  const rel = path.relative(root, file).split(path.sep).join("/");
  lines.forEach((line, i) => {
    const hex = line.match(HEX) ?? [];
    // rgb() in lib/*.ts is pdf-lib's drawing API for the tax PDFs, not CSS.
    const cssLike = /\.(css|tsx)$/.test(file);
    const fn = cssLike ? (line.match(FUNC) ?? []) : [];
    for (const v of [...hex, ...fn]) {
      offenders++;
      if (offenders <= 12) fail(`${rel}:${i + 1} writes a colour (${v}) outside app/tokens.css`);
    }
    if (/\.css$/.test(file) && /@import\s+url\(["']?https?:/.test(line)) {
      fail(`${rel}:${i + 1} imports a stylesheet from the internet; fonts are self-hosted`);
    }
  });
}
if (offenders > 12) fail(`...and ${offenders - 12} more colour values outside app/tokens.css`);
if (offenders === 0) ok(`no colour is written outside app/tokens.css (${sources.length} files checked)`);

// ── one type scale, one motion, nothing faded ────────────────
const tokenText = readFileSync(TOKENS, "utf8");
const scale = [...tokenText.matchAll(/--text-([a-z0-9]+):\s*([\d.]+)px;/g)].map((m) => ({ name: m[1], px: Number(m[2]) }));
if (scale.length < 5) fail("tokens.css has no type scale (--text-*)");
else if (scale.some((t, i) => i > 0 && t.px <= scale[i - 1].px)) fail("the --text-* scale in tokens.css is not smallest to largest");
const scaleNames = new Set(scale.map((t) => t.name));
if (!/--motion:\s*200ms ease-in-out;/.test(tokenText)) fail("tokens.css does not set --motion to 200ms ease-in-out");

const rule = { size: 0, motion: 0, fade: 0, glass: 0, dark: 0 };
const say = (kind, msg) => {
  rule[kind]++;
  if (rule[kind] <= 8) fail(msg);
};
const DURATION = /\b\d+(?:\.\d+)?m?s\b/;
for (const file of [...sources.filter((f) => /\.(css|tsx)$/.test(f)), TOKENS]) {
  const rel = path.relative(root, file).split(path.sep).join("/");
  const isTokens = path.resolve(file) === path.resolve(TOKENS);
  let inTransition = false;
  readFileSync(file, "utf8").split(/\r?\n/).forEach((line, i) => {
    const at = `${rel}:${i + 1}`;
    if (!isTokens) {
      for (const m of line.matchAll(/font-size:\s*([^;]+);/g)) {
        const v = m[1].trim();
        const t = v.match(/^var\(--text-([a-z0-9]+)\)$/);
        if (v !== "inherit" && !(t && scaleNames.has(t[1]))) say("size", `${at} sets a font size off the scale (${v}); use var(--text-*)`);
      }
      for (const m of line.matchAll(/fontSize:\s*([^,}]+)/g)) {
        const t = m[1].trim().match(/^"var\(--text-([a-z0-9]+)\)"$/);
        if (!(t && scaleNames.has(t[1]))) say("size", `${at} sets a font size off the scale (${m[1].trim()}); use "var(--text-*)"`);
      }
      // A transition or animation, on one line or a list over several: every
      // part of it runs on --motion, and none names a duration.
      const start = line.match(/\b(transition|animation)(?:-duration)?\s*:\s*(.*)$/);
      const body = start ? start[2] : inTransition ? line : null;
      if (body !== null) {
        if (DURATION.test(body)) say("motion", `${at} names a duration of its own; use var(--motion)`);
        else if (body.trim() && body.trim() !== ";" && !/var\(--motion\)/.test(body))
          say("motion", `${at} animates without --motion (${body.trim()})`);
        inTransition = !body.includes(";");
      }
    }
    for (const m of line.matchAll(/\bopacity:\s*([^;,}]+)/g)) {
      if (Number(m[1].trim()) !== 1) say("fade", `${at} fades something with opacity (${m[1].trim()}); text is never faded`);
    }
    // The fill gold is 2.1:1 on cream: as text it is --accent-text, always.
    if (!isTokens && /(^|[^-])color:\s*"?var\(--accent\)/.test(line))
      say("fade", `${at} uses the fill gold as text; use var(--accent-text)`);
    if (/backdrop-filter/.test(line)) say("glass", `${at} uses backdrop-filter; no glass`);
    if (/border[a-z-]*\s*:[^;]*var\(--scrim\)/.test(line)) say("glass", `${at} draws a border with --scrim; no translucent borders`);
    if (/prefers-color-scheme|data-theme/.test(line)) say("dark", `${at} adds a dark mode; there is none`);
  });
}
if (rule.size === 0) ok(`every font size is on the ${scale.length}-step scale (${scale.map((t) => t.px).join(" / ")} px)`);
if (rule.motion === 0) ok("every transition and animation runs on --motion (200ms ease-in-out)");
if (rule.fade + rule.glass + rule.dark === 0) ok("no faded text, no glass, no translucent borders, no dark mode");
for (const k of Object.keys(rule)) if (rule[k] > 8) fail(`...and ${rule[k] - 8} more like that`);

// ── contrast ─────────────────────────────────────────────────
const tokens = new Map();
for (const m of readFileSync(TOKENS, "utf8").matchAll(/--([a-z0-9-]+):\s*([^;]+);/g)) {
  tokens.set(m[1], m[2].trim());
}
const resolve = (name, depth = 0) => {
  const v = tokens.get(name);
  if (!v) throw new Error(`no token --${name}`);
  const ref = v.match(/^var\(--([a-z0-9-]+)\)$/);
  if (ref && depth < 10) return resolve(ref[1], depth + 1);
  return v;
};
const lum = (hex) => {
  const h = hex.replace("#", "");
  const full = h.length === 3 ? [...h].map((c) => c + c).join("") : h.slice(0, 6);
  const [r, g, b] = [0, 2, 4].map((i) => parseInt(full.slice(i, i + 2), 16) / 255);
  const lin = (c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
};
const ratio = (a, b) => {
  const [x, y] = [lum(resolve(a)), lum(resolve(b))].sort((p, q) => q - p);
  return (x + 0.05) / (y + 0.05);
};

// Every pair the stylesheet puts text on, and the edges a person has to see.
const TEXT = [
  ["ink", "bone"], ["ink", "paper"], ["ink-2", "bone"], ["ink-2", "paper"],
  ["muted", "bone"], ["muted", "paper"], ["muted", "accent-soft-hover"],
  // Gold as text on cream is --accent-text; the fill gold carries ink.
  ["accent-text", "paper"], ["accent-text", "bone"], ["accent-text", "accent-soft"], ["accent-text", "accent-soft-hover"],
  ["accent-ink", "accent"], ["accent-ink", "accent-hover"],
  ["ink", "accent-soft-hover"], ["ink", "warn-soft"], ["ink", "ok-soft"], ["ink", "bad-soft"],
  ["ok", "paper"], ["ok-ink", "ok-soft"],
  ["warn-ink", "paper"], ["warn-ink", "warn-soft"],
  ["bad", "paper"], ["bad", "bone"], ["bad", "bad-soft"],
  ["ink-2", "accent-soft"],
  // a chosen row, a disabled control, a figure under the pointer
  ["ink", "accent-soft"], ["muted", "accent-soft"],
  ["bad", "accent-soft-hover"], ["warn-ink", "accent-soft-hover"],
  ["disabled-ink", "disabled-bg"],
  // the dark sidebar: its text, the current item, its small print
  ["side-ink", "side-bg"], ["side-ink", "side-hover"], ["side-ink", "side-active-bg"],
  ["side-active-ink", "side-active-bg"], ["side-active-ink", "side-bg"],
  ["side-muted", "side-bg"], ["side-muted", "side-hover"],
];
const EDGES = [
  ["field-line", "paper"], ["field-line", "bone"],
  ["focus", "paper"], ["focus", "bone"],
  // the sparkline's line, and a progress bar's fill against its track
  ["accent-text", "paper"], ["accent-text", "line-strong"],
  // the focus ring on the dark panel
  ["side-active-ink", "side-bg"], ["side-active-ink", "side-hover"],
];

let worst = Infinity;
for (const [fg, bg] of TEXT) {
  const r = ratio(fg, bg);
  worst = Math.min(worst, r);
  if (r < 4.5) fail(`text --${fg} on --${bg} is ${r.toFixed(2)}:1, under 4.5:1`);
}
if (!problems.some((p) => p.startsWith("text "))) ok(`all ${TEXT.length} text pairs reach 4.5:1 (lowest ${worst.toFixed(2)}:1)`);

for (const [fg, bg] of EDGES) {
  const r = ratio(fg, bg);
  if (r < 3) fail(`--${fg} against --${bg} is ${r.toFixed(2)}:1, under 3:1 for a control edge`);
}
if (!problems.some((p) => p.includes("control edge"))) ok("text-field edges and the focus ring reach 3:1");

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- THEME VERIFIED ---");
