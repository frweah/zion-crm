/**
 * An invoice number comes from the ledger, and nothing else hands one out.
 *
 *   node scripts/check-invoice-numbers.mjs
 *
 * A Zion invoice number is a claim identifier the state sees, and the five
 * invoices still owed carry 955662-955666 by the owner's ruling of 6 November
 * 2026: "keep the ledger numbers; the sequence continues from them."
 *
 * It had not been continuing from them. The number came from a sequence, and
 * a sequence is deliberately not transactional: every verification script
 * builds its fixtures against production inside begin/rollback, three of them
 * invoices, and the rows went away while the numbers did not. A hundred and
 * thirty-eight of the practice's invoice numbers had been spent on invoices
 * that never existed, and twenty-five more in October before that.
 *
 * 0323 took the sequence out: the next number is one past the end of the
 * ledger, worked out when the row is written, so a rolled-back fixture leaves
 * no row and therefore spends nothing. What is asked here is that it stays
 * that way - a `default nextval(...)` put back on the column would be a quiet
 * return to the same gap, and it would be nobody's intention.
 *
 * The behaviour itself is in supabase/verify_invoice_numbers.sql, which can
 * ask the database. This is the half that does not need credentials.
 */
import { readFile, readdir } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const MIG = new URL("../supabase/migrations/", import.meta.url);
const names = (await readdir(MIG)).filter((n) => n.endsWith(".sql")).sort();
const files = [];
for (const name of names) {
  files.push({ name, body: (await readFile(new URL(name, MIG), "utf8")).replace(/\r\n/g, "\n") });
}

// ── the sequence is gone, and the last word on it is the one that said so ──
const mentions = files.filter((f) => f.body.includes("zion_invoice_number"));
const last = mentions[mentions.length - 1];
if (!last) {
  fail("no migration mentions the invoice number sequence at all, so this check has nothing to hold");
} else if (!/drop\s+sequence\s+if\s+exists\s+public\.zion_invoice_number/i.test(last.body)) {
  fail(
    `${last.name} is the newest migration to mention the invoice number sequence and it does not drop it — ` +
      "a sequence is not rolled back, so a fixture that rolls back still spends a number",
  );
} else {
  ok(`the invoice number sequence is dropped by ${last.name}, the last migration to name it`);
}

// ── and nothing gives the column a default back ──
// Looked for in every migration, not only the newest: a default added in one
// and dropped in a later one is fine, a default added after the drop is not.
const dropAt = names.indexOf(last?.name ?? "");
const defaulted = files
  .slice(dropAt + 1)
  .filter((f) => /alter\s+column\s+number\s+set\s+default|number\s+bigint[^,]*default/i.test(f.body))
  .map((f) => f.name);
if (defaulted.length) {
  fail(`${defaulted.join(", ")} gives an invoice number a default again, after 0323 took it away`);
} else {
  ok("no migration since gives invoices.number a default");
}

// ── and no screen picks a number ──
// The ledger is read from TypeScript and written only through the database
// functions that say who did it. A number chosen in a screen would be a
// second answer to "what is the next invoice", and the two would disagree.
const SRC = new URL("../", import.meta.url);
const walk = async (dir) => {
  const out = [];
  for (const e of await readdir(new URL(dir, SRC), { withFileTypes: true })) {
    if (e.name === "node_modules" || e.name === ".next" || e.name.startsWith(".")) continue;
    const path = `${dir}${e.name}`;
    if (e.isDirectory()) out.push(...(await walk(`${path}/`)));
    else if (/\.tsx?$/.test(e.name)) out.push(path);
  }
  return out;
};
const sources = [...(await walk("app/")), ...(await walk("lib/"))];
const writers = [];
for (const path of sources) {
  const body = await readFile(new URL(path, SRC), "utf8");
  if (/\.from\(\s*["']invoices["']\s*\)\s*[\s\S]{0,40}?\.(insert|upsert|update)\(/.test(body)) {
    writers.push(path);
  }
}
if (writers.length) {
  fail(`${writers.join(", ")} writes to the invoice ledger directly; it is written through the functions`);
} else {
  ok(`none of the ${sources.length} screens and modules writes an invoice row itself`);
}

for (const p of problems) console.error(`  FAILED  ${p}`);
process.exit(problems.length ? 1 : 0);
