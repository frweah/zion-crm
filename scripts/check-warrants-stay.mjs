/**
 * Warrants stay in Admin.
 *
 * The owner's ruling, 14 November 2026: a warrant stub, a warrant line, a
 * voucher number and a warrant total are Admin's, and Billing sees the
 * outcome - Paid or Short-paid, the day, the amount. Everything
 * warrant-related lives on Admin → Warrants and nowhere else.
 *
 * The database holds most of that: the warrant columns on `payments`,
 * `invoices` and `authorizations` are granted to nobody signed in, the three
 * warrant tables and the storage bucket name Admin, and `verify_warrants`
 * asserts a Billing session can read none of it.
 *
 * This holds the half no grant can. A column grant stops a read; it does not
 * stop somebody putting a warrant column back on a screen and then widening
 * the grant to make the screen work, which is exactly how the folder came to
 * be Billing's in the first place - the tables said `staff_has_area('billing')`
 * and so the screens did too, and nobody wrote down that they should not.
 *
 * So: a warrant column may be named in `app/(app)/admin/warrants/`, and
 * nowhere else under `app/`. `lib/` is asked separately, because the shared
 * readers there are the ones that must not quietly grow a warrant column back.
 *
 * Put the fault back before trusting this: add `warrant_no` to the payments
 * select on the Billing page and watch it fail.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

/**
 * The columns themselves, as a screen would name them.
 *
 * `warrant_date` and `warrant_no` are on payments; `warrant` and `voucher` on
 * invoices and authorizations; `warrant_line_id` is the link to the stub.
 * Written as the exact column names rather than as the word "warrant", because
 * the word is everywhere in the comments explaining why a screen does not have
 * one - and a check that failed those is a check somebody deletes.
 */
const COLUMNS = ["warrant_no", "warrant_date", "warrant_line_id", "voucher"];

/**
 * Where a warrant may be read, and why.
 *
 * One screen, and the reader that puts the stubs in. Nothing here is a screen
 * a person browses except the first: anything else added to this list would be
 * the beginning of the second warrant screen the ruling exists to prevent.
 */
const MAY_READ = [
  // The screen itself: the import, the list, the lines waiting, the payments
  // with no stub, and the warrants that do not add up.
  "app/(app)/admin/warrants/",
  // The reader's own routes. It runs as the service role with nobody signed
  // in, which is how a stub gets into the practice at all - it has no screen
  // and no role, so no grant of Admin's is being spent here.
  "app/api/agent/warrants/",
  // What a stub says, read off the page.
  "lib/warrant-parse.ts",
  // Which document is a stub and which page of it is which.
  "lib/warrant-routing.ts",
  // Names the column to keep it out of every CSV, which is the opposite of a
  // read: RESTRICTED_COLUMNS is the list check-exports holds the route to.
  "lib/exports.ts",
];

/** The tables and the function only Admin may ask. */
const ADMIN_ONLY_SOURCES = [
  "warrant_pages",
  "warrant_lines",
  "warrant_documents",
  "payment_waiting_for_its_warrant",
  "warrants_not_accounted_for",
  "reconcile_warrant_line",
  "reconcile_warrant_page",
  "add_warrant_line",
  "correct_warrant_line",
  "dismiss_warrant_line",
];

function walk(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".next") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...walk(full));
    else if (/\.(ts|tsx)$/.test(entry.name)) out.push(full);
  }
  return out;
}

/** Code with the comments taken out: the house style explains, at length. */
function codeOf(src) {
  return src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
}

let asked = 0;
const files = walk(path.join(root, "app")).concat(walk(path.join(root, "lib")));
for (const file of files) {
  const where = path.relative(root, file).replaceAll("\\", "/");
  if (where === "lib/database.types.ts") continue;
  if (MAY_READ.some((d) => where.startsWith(d))) {
    asked += 1;
    continue;
  }
  const code = codeOf(readFileSync(file, "utf8"));

  for (const column of COLUMNS) {
    // A column is read when it is named in a select list, destructured, or
    // reached for off a row. `p_voucher` and `p_warrant` are arguments to a
    // database function, which is a write and is guarded there.
    const named = new RegExp(`(^|[^\\w.$])${column}\\s*(:|,|\\}|\\)|\\?)|\\.${column}\\b|["'][^"']*\\b${column}\\b[^"']*["']`);
    if (!named.test(code)) continue;
    if (new RegExp(`p_${column}|p_warrant\\b`).test(code) && !named.test(code.replace(/p_\w+/g, ""))) continue;
    failures.push(
      `${where} names the ${column} column. A warrant is read on Admin → Warrants; ` +
        "if it genuinely belongs here, say why in scripts/check-warrants-stay.mjs.",
    );
  }

  for (const source of ADMIN_ONLY_SOURCES) {
    if (!new RegExp(`["'\`]${source}["'\`]`).test(code)) continue;
    failures.push(
      `${where} reads ${source}, which is Admin's. It belongs under app/(app)/admin/warrants/.`,
    );
  }
}

// And the list cannot rot into naming something that is gone. Each entry is a
// directory or a single file, so it is asked as a path rather than as a
// listing - the first version of this check called readdirSync on all five and
// reported the three files as missing.
for (const entry of MAY_READ) {
  try {
    statSync(path.join(root, entry));
  } catch {
    failures.push(`${entry} is allowed to read warrants and does not exist.`);
  }
}

if (asked === 0) {
  failures.push(
    "Nothing under app/(app)/admin/warrants/ was read, which cannot be right - that is the warrants screen.",
  );
}

if (failures.length) {
  console.error("check-warrants-stay FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(`  ok  a warrant column is named in ${asked} file(s), all of them Admin → Warrants`);
console.log("\n--- WARRANTS STAY IN ADMIN ---");
