/**
 * No client's name is in the repository.
 *
 *   node --env-file=.env.local scripts/check-no-client-names.mjs
 *
 * Run by hand, and listed in `check-checks` as a check that cannot run in
 * prebuild, with the reason: it has to ask the database who the clients are,
 * and prebuild runs on Vercel where there are no database credentials. There
 * is no snapshot to fall back on either, for the obvious reason - a list of
 * client names committed to the repository would be the thing this is for.
 *
 * Fifteen real people were named across three files until 4 November 2026: the
 * build log, one migration comment, and one spent one-off script that looked a
 * client up by name because the duplicate had no client number. Each now has a
 * stand-in, and the one-off looks the row up by its id.
 *
 * What it does not treat as a failure, and why:
 *
 *   * A surname on its own. It may be a client's, and it may equally be a
 *     counselor's, a USOR finance contact's, or a generic example - "Smith,
 *     John" in a comment about folder names. Those are reported for somebody
 *     to read rather than failing a build.
 *   * A surname that is also a staff member's. The house style names staff in
 *     comments, and that is not client data.
 *   * "The assessment is due", which is in `clients.name` because a parser bug
 *     turned a sentence off a USOR form into a client. Every comment quoting it
 *     is about the bug, and scrubbing it would delete the point.
 *
 * Nothing here prints a name. Where it is, is enough to go and look.
 */
import { Client } from "pg";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";

const db = new Client({
  host: process.env.SUPABASE_DB_HOST,
  port: Number(process.env.SUPABASE_DB_PORT ?? 5432),
  user: process.env.SUPABASE_DB_USER ?? "postgres",
  password: process.env.SUPABASE_DB_PASSWORD,
  database: process.env.SUPABASE_DB_NAME ?? "postgres",
  ssl: { rejectUnauthorized: false },
});

if (!process.env.SUPABASE_DB_HOST || !process.env.SUPABASE_DB_PASSWORD) {
  console.error("This needs the database: run it with --env-file=.env.local");
  process.exit(1);
}

await db.connect();
const { rows: clients } = await db.query(
  "select id, name from public.clients where name not like 'ZZ %' and name not like 'ZQ %'",
);
const { rows: staff } = await db.query("select name from public.staff");
await db.end();

const staffWords = new Set(
  staff.flatMap((s) => (s.name ?? "").split(/\s+/)).map((w) => w.toLowerCase()),
);

const files = execSync("git ls-files", { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
  .split("\n")
  .map((f) => f.trim())
  .filter(Boolean);

const BOGUS = /assessment is due/i;

const targets = [];
for (const c of clients) {
  const full = (c.name ?? "").trim();
  if (full.split(/\s+/).length < 2 || BOGUS.test(full)) continue;
  targets.push({ kind: "full", text: full, name: full });
  const surname = full.split(/\s+/).slice(-1)[0];
  if (surname.length >= 5 && !staffWords.has(surname.toLowerCase())) {
    targets.push({ kind: "surname", text: surname, name: full });
  }
}

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, (m) => "\\" + m);

const named = [];
const maybe = [];
for (const f of files) {
  let src;
  try {
    src = readFileSync(f, "utf8");
  } catch {
    continue;
  }
  const lines = src.split("\n");
  for (const t of targets) {
    if (!src.includes(t.text)) continue;
    const re = new RegExp("\\b" + escape(t.text) + "\\b");
    lines.forEach((l, i) => {
      if (!re.test(l)) return;
      (t.kind === "full" ? named : maybe).push({ file: f, line: i + 1 });
    });
  }
}

for (const h of named) {
  console.error(`  FAILED  ${h.file}:${h.line} names a client in full`);
}

if (named.length === 0) {
  console.log(`  ok  no client is named in full in any of ${files.length} tracked files`);
}

const byFile = new Map();
for (const h of maybe) {
  if (!byFile.has(h.file)) byFile.set(h.file, new Set());
  byFile.get(h.file).add(h.line);
}
if (byFile.size > 0) {
  console.log(
    `  ok  ${maybe.length} surname(s) a client shares appear in ${byFile.size} file(s). ` +
      `Read them rather than trusting this line:`,
  );
  for (const [f, lines] of [...byFile].sort()) {
    console.log(`        ${f}:${[...lines].sort((a, b) => a - b).join(",")}`);
  }
}

if (named.length > 0) {
  console.error("\nFAILED");
  process.exit(1);
}
console.log("\n--- NO CLIENT NAMES VERIFIED ---");
