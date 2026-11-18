/**
 * The stage board is the whole team's screen.
 *
 * Clients › Board shows every active client to every role, which is what
 * makes it the most useful screen in the practice and the easiest one to
 * leak through. The brief drew the line: no money, no warrant data, no
 * Personal notes, no transcripts. `supabase/verify_clients_board.sql` asks
 * the database the same question; this asks the screen, before the build.
 *
 * And one thing only a static read can ask: that every column the grid
 * offers draws something. A column in the Columns menu whose key has no case
 * in the cell switch is a column that turns on and shows an empty strip, and
 * nothing at run time complains.
 */
import { readFileSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];
const read = (p) => readFileSync(path.join(root, p), "utf8");

const GRID = "app/(app)/clients/stage-board.tsx";
const SHAPE = "lib/clients-board-shape.ts";
const FUNCTION = "supabase/migrations/0371_the_board_reads_one_row_per_client.sql";

/** What may not be on this screen, and the word each one would appear as. */
const FORBIDDEN = /\b(warrant|voucher|invoice|invoiced|amount|outstanding|authorized|transcript|turns)\b/i;

for (const where of [GRID, SHAPE]) {
  const src = read(where);
  // Comments are never judged: the house style explains in prose what a
  // screen is careful not to show, and those sentences name the things.
  const code = src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
  const hit = code.match(FORBIDDEN);
  if (hit) {
    failures.push(
      `${where} names "${hit[0]}". The stage board is read by every role: no money, no warrant data, no transcript.`,
    );
  }
  if (/\bPersonal\b/.test(code)) {
    failures.push(`${where} names a Personal note, which is read on the Notes tab and nowhere else.`);
  }
}

// The row function, asked of its signature rather than of its body: the body
// reads authorizations on purpose, for the one date the board carries.
const sql = read(FUNCTION);
const returns = sql.slice(sql.indexOf("returns table ("), sql.indexOf("language sql"));
const named = [...returns.matchAll(/^\s{2}([a-z_0-9]+)\s/gm)].map((m) => m[1]);
const money = named.filter((c) => /warrant|voucher|invoice|amount|paid|rate|transcript|personal/i.test(c));
if (money.length) {
  failures.push(`${FUNCTION} returns ${money.join(", ")} — the board carries no money.`);
}
if (named.length < 10) {
  failures.push(`${FUNCTION}: only ${named.length} returned columns were found, so this check is not reading the signature.`);
}

// Every column the grid offers draws something.
const grid = read(GRID);
const columns = [...grid.matchAll(/\{\s*key:\s*"([a-z0-9]+)"\s*,\s*label:/gi)].map((m) => m[1]);
const drawn = new Set([...grid.matchAll(/case\s+"([a-z0-9]+)"\s*:/gi)].map((m) => m[1]));
const undrawn = columns.filter((c) => !drawn.has(c));
if (undrawn.length) {
  failures.push(`${GRID}: the Columns menu offers ${undrawn.join(", ")}, and the row draws nothing for them.`);
}
if (columns.length < 10) {
  failures.push(`${GRID}: only ${columns.length} columns were found, so this check is not reading the grid.`);
}

// And every column the row draws is a column somebody can turn on.
const extra = [...drawn].filter((c) => !columns.includes(c));
if (extra.length) {
  failures.push(`${GRID}: the row draws ${extra.join(", ")}, which is in no column.`);
}

if (failures.length) {
  console.error("check-clients-board FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(
  `check-clients-board ok — ${columns.length} columns, every one drawn, and no money, warrant or transcript on the screen`,
);
