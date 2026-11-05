/**
 * Nobody emails a robot.
 *
 *   node scripts/check-who-gets-mail.mjs
 *
 * 0120 said the check accounts are "left out of every mailing and every list
 * of colleagues", and for a year that was free: they were Job Search, and
 * nothing addressed by role ever addressed them. 0294 made one of them an
 * Admin so the timing walk could open Admin's screens, and the Monday health
 * run - which picks every active Admin - put automated-check-admin@ in the To
 * line of the owner's first forced send. An address nothing is ever sent to.
 *
 * It was one query of the twelve that read an address out of the staff table;
 * the other eleven already said `is_system: false`. That is the shape of this
 * fault: a rule everybody follows and nothing holds, so the day a premise
 * changes underneath it, the one place that forgot is found by somebody
 * reading a To line.
 *
 * The rule: a query that reads an address out of `staff` for sending has to
 * say who is not a person. A query that names one row - `.eq("id", …)` - is
 * somebody in particular and is exempt, because picking a named person is not
 * addressing by role.
 */
import { readdir, readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const problems = [];
const fail = (said) => problems.push(said);
const ok = (said) => console.log(`  ok  ${said}`);

/** Every .ts and .tsx under a directory. */
async function* sources(dir) {
  for (const e of await readdir(dir, { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === ".next") continue;
    const at = new URL(e.name + (e.isDirectory() ? "/" : ""), dir);
    if (e.isDirectory()) yield* sources(at);
    else if (/\.tsx?$/.test(e.name)) yield at;
  }
}

// Forward slashes, always, and never path.join: a path-keyed comparison built
// with it passes on Windows and matches nothing on Linux, which is how eight
// deploys failed while every local run was green.
const ROOT = fileURLToPath(new URL("../", import.meta.url)).split("\\").join("/");
const rel = (url) => fileURLToPath(url).split("\\").join("/").slice(ROOT.length);

/**
 * One query, as written: from `.from("staff")` to the end of the chain.
 *
 * Read as text rather than parsed, which is enough because every one of these
 * is a single chained expression. The end of the chain is the first line that
 * is not part of it - a blank line, a closing bracket at the chain's own
 * indentation, or another `.from(`.
 */
function queries(text) {
  const out = [];
  const lines = text.split("\n");
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].includes('.from("staff")')) continue;
    let chunk = lines[i];
    for (let j = i + 1; j < lines.length && j < i + 14; j++) {
      const line = lines[j];
      if (line.includes('.from(') || line.trim() === "") break;
      chunk += "\n" + line;
      // A chain ends at the line that does not continue it.
      if (!/[.,]\s*$/.test(line.trim()) && !/^\s*\./.test(lines[j + 1] ?? "")) break;
    }
    out.push({ line: i + 1, chunk });
  }
  return out;
}

let checked = 0;
const exempt = [];
for (const dir of ["app/", "lib/"]) {
  for await (const file of sources(new URL(`../${dir}`, import.meta.url))) {
    const text = await readFile(file, "utf8");
    for (const { line, chunk } of queries(text)) {
      // Only the ones that read an address. A query for names, roles or ids
      // is not a mailing list.
      if (!/select\([^)]*\bemail\b/s.test(chunk)) continue;
      checked++;

      // Somebody in particular, by id. Not addressing by role.
      if (/\.eq\(\s*"id"\s*,/.test(chunk) || /\.in\(\s*"id"\s*,/.test(chunk)) {
        exempt.push(`${rel(file)}:${line}`);
        continue;
      }

      if (!/is_system/.test(chunk)) {
        fail(
          `${rel(file)}:${line} reads an address out of staff without saying who is not a person - ` +
            `add .eq("is_system", false), or narrow it to one person by id`,
        );
      }
    }
  }
}

if (checked === 0) {
  fail("no query reads an address out of the staff table, which cannot be right - this check is asking about nothing");
}

if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}

ok(`all ${checked} queries that read an address out of staff leave the system accounts out`);
if (exempt.length) {
  ok(`${exempt.length} of them name one person by id, which is not addressing by role`);
}
console.log("\n--- WHO GETS MAIL VERIFIED ---");
