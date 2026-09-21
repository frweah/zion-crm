/**
 * Server code that reaches into a "use client" file for anything but a
 * component.
 *
 *   node scripts/check-client-imports.mjs     (also runs before every build)
 *
 * A "use client" file is a boundary. A server page may render its components
 * - <AddLeadForm /> - and nothing else crosses: a list, a function, a
 * constant exported from it arrives on the server as a reference to
 * something that exists only in the browser. TypeScript cannot see this,
 * the build passes, and the page fails at the first line that uses it.
 *
 * That is how Clients → Jobs went down on 21 Sept 2026: the page sorted by
 * LEAD_STATUSES imported from leads-forms.tsx, a client file. With no jobs
 * the sort never ran; the spreadsheet import added 255 and every visit to
 * the screen was a server error.
 *
 * So: for every file that is not itself a client file, every value it imports
 * from a client file must be used only as a JSX tag. A type is fine; a
 * constant, a helper or a list belongs somewhere both sides can read, such as
 * lib/constants.ts.
 */
import { readdirSync, readFileSync, statSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (name === "node_modules" || name.startsWith(".")) return [];
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
const files = ["app", "lib"].flatMap((d) => walk(path.join(root, d))).filter((f) => /\.(ts|tsx)$/.test(f));
const rel = (f) => path.relative(root, f).split(path.sep).join("/");

const source = new Map(files.map((f) => [f, readFileSync(f, "utf8")]));
const stripComments = (s) => s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:"'`])\/\/.*$/gm, "$1");
const isClient = (s) => /^\s*(?:\/\/[^\n]*\n|\/\*[\s\S]*?\*\/\s*)*\s*["']use client["']/.test(s);

function resolve(from, spec) {
  let base;
  if (spec.startsWith("@/")) base = path.join(root, spec.slice(2));
  else if (spec.startsWith(".")) base = path.resolve(path.dirname(from), spec);
  else return null;
  for (const c of [base, `${base}.tsx`, `${base}.ts`, path.join(base, "index.tsx"), path.join(base, "index.ts")]) {
    if (existsSync(c) && statSync(c).isFile()) return c;
  }
  return null;
}

const problems = [];
let checked = 0;
const importRe = /import\s+(type\s+)?([\s\S]*?)\s+from\s+["']([^"']+)["']/g;

for (const [file, raw] of source) {
  if (isClient(raw)) continue;
  const code = stripComments(raw);
  for (const m of code.matchAll(importRe)) {
    if (m[1]) continue; // import type { ... }
    const target = resolve(file, m[3]);
    if (!target || !isClient(source.get(target) ?? "")) continue;

    const names = [];
    const clause = m[2].trim();
    const braces = clause.match(/\{([\s\S]*)\}/);
    const def = clause.replace(/\{[\s\S]*\}/, "").replace(/,\s*$/, "").trim();
    if (def && !def.startsWith("*")) names.push(def);
    if (braces) {
      for (const part of braces[1].split(",")) {
        const p = part.trim();
        if (!p || p.startsWith("type ")) continue;
        names.push(p.split(/\s+as\s+/).pop().trim());
      }
    }

    // Everywhere else the name appears: only as <Name or </Name.
    const body = code.replace(m[0], "");
    for (const name of names) {
      checked++;
      const uses = [...body.matchAll(new RegExp(String.raw`(^|[^\w$.])${name.replace(/\$/g, "\\$")}(?![\w$])`, "g"))];
      const bad = uses.filter((u) => {
        const before = body.slice(Math.max(0, u.index + u[1].length - 2), u.index + u[1].length);
        return !/<\/?$/.test(before);
      });
      if (bad.length) {
        problems.push(`${rel(file)} uses ${name} from ${rel(target)} (a "use client" file) as a value, not a component`);
      }
    }
  }
}

if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error(`\nMove it to a file both sides can read (lib/constants.ts, or a module without "use client").`);
  process.exit(1);
}
console.log(`  ok  ${checked} imports from "use client" files, every one used only as a component`);
console.log("\n--- CLIENT BOUNDARY VERIFIED ---");
