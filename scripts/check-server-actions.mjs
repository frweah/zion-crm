/**
 * A "use server" file exports async functions and nothing else.
 *
 *   node scripts/check-server-actions.mjs   (also runs before every `npm run build`)
 *
 * Every export of a `"use server"` file becomes a callable server endpoint,
 * so an exported object is a contradiction: there is nothing to call. React
 * refuses the module when it is required — *A "use server" file can only
 * export async functions, found object* — and that refusal is a 500 with a
 * digest and nothing in the browser console.
 *
 * It took production down on 19 Oct. `EMPTY_BATCH`, the starting state of the
 * billing worklist form, sat in `billing/authorizations/actions.ts` next to
 * the actions that return it, which reads well and is not allowed. The same
 * mistake was in `billing/import/actions.ts` as `emptyImport`. Between them
 * they covered adding an authorization, editing one, the confirm queue and
 * submitting — every billing action one person had.
 *
 * **Nothing caught it.** `tsc` is happy: the types are correct. `next build`
 * is happy: the check is React's and it runs when the module is first
 * required on a request, which on a dynamic route is in production, under a
 * real person. The build that shipped it passed every check in `prebuild`.
 * That is the whole reason this file exists — the rule had no owner.
 *
 * What is allowed: `export async function`, and types, which are erased
 * before any of this matters. Anything else is reported, because the cost of
 * being wrong here is a screen that cannot be used at all.
 */
import { sourceFiles, rel, readFile, withoutComments } from "./copy-text.mjs";

const ROOTS = [new URL("../app/", import.meta.url), new URL("../lib/", import.meta.url)];
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);

/** The directive has to be the first thing in the file to mean anything. */
const isServerFile = (src) => /^\s*(?:\/\*[\s\S]*?\*\/\s*|\/\/[^\n]*\n\s*)*["']use server["']/.test(src);

let filesSeen = 0;
let exportsSeen = 0;

for (const root of ROOTS) {
  for (const url of await sourceFiles(root, [".ts", ".tsx"])) {
    const raw = await readFile(url, "utf8");
    if (!isServerFile(raw)) continue;
    const path = rel(url);
    filesSeen++;

    const src = withoutComments(raw);
    const lineAt = (i) => src.slice(0, i).split("\n").length;

    for (const m of src.matchAll(/^export\s+(?!type\b|interface\b)(\w+|\{|\*)([^\n]*)/gm)) {
      exportsSeen++;
      const [whole, head, rest] = m;
      const where = `${path}:${lineAt(m.index)}`;

      // The one allowed shape.
      if (head === "async" && /^\s+function\b/.test(rest)) continue;

      // `export { a, b }` — allowed only if each name is an async function
      // declared in this file. A re-export cannot be checked from here.
      if (head === "{") {
        const names = (whole.match(/\{([^}]*)\}/)?.[1] ?? "")
          .split(",")
          .map((n) => n.trim().split(/\s+as\s+/)[0])
          .filter(Boolean);
        if (/from\s+["']/.test(whole)) {
          problems.push(
            `${where} re-exports ${names.join(", ")} from another module. ` +
              `A "use server" file cannot vouch for what it did not declare — ` +
              `import it where it is used instead.`,
          );
          continue;
        }
        for (const name of names) {
          if (!new RegExp(`\\basync function ${name}\\b`).test(src)) {
            problems.push(
              `${where} exports ${name}, which is not an async function declared here. ` +
                `Every export of a "use server" file becomes a callable endpoint.`,
            );
          }
        }
        continue;
      }

      if (head === "function") {
        problems.push(
          `${where} exports a function that is not async. ` +
            `A "use server" export has to be awaitable from the browser.`,
        );
        continue;
      }

      if (head === "default") {
        problems.push(`${where} has a default export. A "use server" file exports named actions.`);
        continue;
      }

      if (head === "const" || head === "let" || head === "var") {
        // `export const go = async () => {}` is a function, and fine.
        if (/=\s*async\s*(\(|function\b)/.test(rest)) continue;
        const name = rest.trim().split(/[:=\s]/)[0];
        problems.push(
          `${where} exports ${name}, which is not a function. ` +
            `React refuses the whole module when it is required — the screen 500s with a ` +
            `digest and the browser console stays empty. Move it to a plain module; ` +
            `lib/billing.ts is where the billing ones went.`,
        );
        continue;
      }

      if (head === "*") {
        problems.push(`${where} re-exports everything from another module. Name the actions instead.`);
        continue;
      }

      problems.push(`${where} exports something this check does not recognise: ${whole.slice(0, 60)}`);
    }
  }
}

if (filesSeen === 0) {
  problems.push('no "use server" file was found under app/ or lib/. Has the directive moved?');
}

if (problems.length === 0) {
  ok(`all ${exportsSeen} exports across ${filesSeen} "use server" files are async functions`);
  console.log("");
  console.log("--- SERVER ACTIONS VERIFIED ---");
} else {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}
