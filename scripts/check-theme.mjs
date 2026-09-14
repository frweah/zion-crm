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
  ["accent", "paper"], ["accent", "bone"], ["accent", "accent-soft"],
  ["accent-ink", "accent"], ["accent-ink", "accent-hover"],
  ["ink", "accent-soft-hover"], ["ink", "warn-soft"], ["ink", "ok-soft"], ["ink", "bad-soft"],
  ["ok", "paper"], ["ok-ink", "ok-soft"],
  ["warn-ink", "paper"], ["warn-ink", "warn-soft"],
  ["bad", "paper"], ["bad", "bone"], ["bad", "bad-soft"],
  ["ink-2", "accent-soft"],
];
const EDGES = [
  ["field-line", "paper"], ["field-line", "bone"],
  ["focus", "paper"], ["focus", "bone"],
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
