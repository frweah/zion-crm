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
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { REQUESTS_TILE, TILES, tilesFor } from "../lib/clients-board-shape.ts";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];
const read = (p) => readFileSync(path.join(root, p), "utf8");

const GRID = "app/(app)/clients/stage-board.tsx";
const SHAPE = "lib/clients-board-shape.ts";

/**
 * The migration that defines the row function as it now stands.
 *
 * Found rather than named: it was named, as 0371, and 0372 added five columns
 * to the signature the day after - so this check was reading a definition the
 * database no longer had, and would have gone on passing whatever the live
 * one returned. The last migration that creates the function is the one that
 * says what it returns.
 */
const MIGRATIONS = "supabase/migrations";
const FUNCTION = (() => {
  const named = readdirSync(path.join(root, MIGRATIONS))
    .filter((f) => f.endsWith(".sql"))
    .filter((f) => /function public\.clients_board_rows\(/.test(read(path.join(MIGRATIONS, f))))
    .sort();
  if (!named.length) {
    failures.push("no migration creates clients_board_rows, so this check cannot read its signature.");
    return null;
  }
  return path.join(MIGRATIONS, named[named.length - 1]);
})();

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
const sql = FUNCTION ? read(FUNCTION) : "";
// From this function's own definition, not from the first one in the file:
// 0372 defines move_client above it, and "the first returns table in the
// file" read that one and then everything between the two.
const at = sql.indexOf("function public.clients_board_rows(");
const opens = sql.indexOf("returns table (", at);
const returns = at < 0 ? "" : sql.slice(opens, sql.indexOf("language sql", opens));
const named = [...returns.matchAll(/^\s{2}([a-z_0-9]+)\s/gm)].map((m) => m[1]);
const money = named.filter((c) => /warrant|voucher|invoice|amount|paid|rate|transcript|personal/i.test(c));
if (money.length) {
  failures.push(`${FUNCTION} returns ${money.join(", ")} — the board carries no money.`);
}
if (named.length < 10) {
  failures.push(`${FUNCTION}: only ${named.length} returned columns were found, so this check is not reading the signature.`);
}

// And every column it returns reaches the screen. A column added to the
// function and not to the row's shape is a column that was read, paid for and
// thrown away, and nothing at run time says so.
const shape = read(SHAPE);
const unread = named.filter((c) => !shape.includes(c));
if (unread.length) {
  failures.push(`${SHAPE} does not read ${unread.join(", ")}, which the row function returns.`);
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

/* ── the tiles, and whose they are ──────────────────────────── */
//
// Five for everybody and a sixth for Admin (brief, Part 3). Asked of the
// functions themselves rather than of the source: a tile list that is right
// in the file and wrong when called is the bug this is for.
const forAll = tilesFor(false);
const forAdmin = tilesFor(true);
if (forAll.length !== TILES.length || forAll.some((t) => t.key === REQUESTS_TILE.key)) {
  failures.push(`${SHAPE}: "${REQUESTS_TILE.label}" is offered to somebody who cannot act on it.`);
}
if (forAdmin.length !== TILES.length + 1 || !forAdmin.some((t) => t.key === REQUESTS_TILE.key)) {
  failures.push(`${SHAPE}: Admin does not get "${REQUESTS_TILE.label}".`);
}
// It has to tell the two rows apart, or it is a tile that counts everybody.
const waiting = { stage_request_id: "11111111-1111-1111-1111-111111111111" };
const settled = { stage_request_id: null };
if (!REQUESTS_TILE.holds(waiting, "2026-11-18") || REQUESTS_TILE.holds(settled, "2026-11-18")) {
  failures.push(`${SHAPE}: the requests tile does not tell a waiting request from a decided one.`);
}
// And the grid asks who is looking rather than drawing the whole list.
if (!/tilesFor\(isAdmin\)/.test(grid)) {
  failures.push(`${GRID} does not take its tiles from tilesFor(isAdmin), so the sixth is drawn for everybody.`);
}

if (failures.length) {
  console.error("check-clients-board FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}

console.log(
  `check-clients-board ok — ${columns.length} columns, every one drawn and every one read, ` +
    `${forAll.length} tiles and Admin's ${forAdmin.length}th, and no money, warrant or transcript on the screen`,
);
