/**
 * The transcript never leaves the recording.
 *
 * The owner's rule, 14 November, and the reason for it is the thing itself: a
 * transcript is a machine's record of an hour of somebody talking about their
 * own life - their health, their family, what the state pays them, what their
 * lawyer said. The practice keeps it because it is what was said. What goes
 * on the record is the six parts a person read and agreed to.
 *
 * The database holds half of that: `recordings` is readable only by the
 * people who may open the client's restricted documents, and
 * `verify_recordings` asserts that confirming copies none of the words into
 * the note or the contact log.
 *
 * This holds the other half, which no RLS policy can: **who in the app reads
 * the column at all.** A progress report, a CSV export, a message to a
 * counselor and a mail body are all written by somebody with access, running
 * as themselves, so the database would hand over the transcript without a
 * word. The rule there is not about permission - it is about where the words
 * are allowed to go.
 *
 * So: `transcript` and `turns` on the recordings table may be read on the
 * client record, where the person who may open the audio reads them behind a
 * disclosure, by the route that writes them, and by the records-request
 * bundle in SQL, which answers a client asking for everything the practice
 * holds about them. Nowhere else.
 */
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dirname, "..");
const failures = [];

/**
 * Where the words are allowed to be read, and why each one is on the list.
 *
 * A path is here because a person with the right to open the audio is looking
 * at it themselves, or because the words are being written in the first
 * place. Nothing is here because it was convenient.
 */
const MAY_READ = new Map([
  ["app/(app)/clients/[id]/page.tsx", "the client record, which reads it for the panel below"],
  ["app/(app)/clients/[id]/recordings-panel.tsx", "the panel, behind a disclosure"],
  ["lib/recordings.ts", "Azure's answer, on its way to the database"],
  ["lib/recordings-shape.ts", "the shape itself"],
  ["app/api/cron/recordings/route.ts", "the route that records a reading"],
]);

/** Anything that sends, exports, reports or mails is where this matters most. */
const CARRIES_OFF_THE_RECORD =
  /report|export|csv|mail|message|counselor|portal|records-request|digest|notify|agent/i;

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

/**
 * A read of the column, not a mention of the word.
 *
 * The house style is long comments, and half the files that say "transcript"
 * say it to explain that they do not have one - `lib/microsoft.ts` says a
 * calendar read takes "never a recording, never a transcript". A check that
 * failed those would be a check nobody could keep.
 */
const READS_IT =
  /(^|[^\w.])(transcript|turns)\s*(:|,|\}|\)|\s*\?\?)|["'][^"']*\b(transcript|turns)\b[^"']*["']\s*\)|\.(transcript|turns)\b/;

let asked = 0;
for (const file of walk(path.join(root, "app")).concat(walk(path.join(root, "lib")))) {
  const where = path.relative(root, file).replaceAll("\\", "/");
  if (where === "lib/database.types.ts" || where === "lib/rls-writes.json") continue;
  if (MAY_READ.has(where)) {
    asked += 1;
    continue;
  }
  const src = readFileSync(file, "utf8");
  // Comments are never judged: the house style explains why a thing is not
  // done, and those sentences say "transcript" as often as the code does.
  const code = src
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split("\n")
    .filter((l) => !l.trim().startsWith("//"))
    .join("\n");
  if (!/\brecordings\b/.test(code)) continue;
  if (!READS_IT.test(code)) continue;
  asked += 1;
  failures.push(
    `${where} reads the transcript or the speaker turns off the recordings table. ` +
      (CARRIES_OFF_THE_RECORD.test(where)
        ? "That is a path that sends words somewhere, and the transcript does not leave the recording."
        : "If somebody has to read it there, say why in scripts/check-transcript-stays.mjs."),
  );
}

/**
 * And the same question of the database, which the scan above cannot see.
 *
 * The client's stream started reading `recordings` in SQL (0368) so that a
 * recording shows on the dashboard by name and length. A view is exactly the
 * place this rule gets broken quietly: `select r.*` would put an hour of
 * somebody talking about their own life on the front page of their record,
 * and nothing in the app would have changed.
 *
 * So: a view or a function that reads the recordings table may not name the
 * transcript, the turns or the summary. The one that may is the
 * records-request bundle, which answers a client asking for everything the
 * practice holds about them.
 */
const SQL_MAY_READ = new Set(["records_request_bundle"]);

const migrations = path.join(root, "supabase", "migrations");
let sqlAsked = 0;
for (const name of readdirSync(migrations).filter((f) => f.endsWith(".sql")).sort()) {
  const raw = readFileSync(path.join(migrations, name), "utf8");
  // Comments are never judged here either: a migration explains in prose what
  // it is careful not to do, and those sentences name the transcript.
  const sql = raw
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .split(/\r?\n/)
    .filter((l) => !l.trim().startsWith("--"))
    .join("\n");

  // Statement by statement, so a transcript read inside one function is not
  // excused by a recording read inside another.
  for (const statement of sql.split(/;\s*\r?\n/)) {
    const made = /create\s+(or\s+replace\s+)?(view|function)\s+(public\.)?([a-z_0-9]+)/i.exec(statement);
    if (!made) continue;
    if (!/\brecordings\b/.test(statement)) continue;
    sqlAsked += 1;
    if (SQL_MAY_READ.has(made[4])) continue;
    if (/\b(transcript|turns|summary)\b/.test(statement)) {
      failures.push(
        `supabase/migrations/${name}: ${made[4]} reads the recordings table and names the transcript, ` +
          "the speaker turns or the summary. Those stay on the recording.",
      );
    }
  }
}

if (sqlAsked === 0) {
  failures.push(
    "No view or function in the migrations reads the recordings table, which cannot be right — the client's stream shows them.",
  );
}

// And the list itself cannot rot into naming files that are gone.
for (const [where] of MAY_READ) {
  try {
    readFileSync(path.join(root, where));
  } catch {
    failures.push(`${where} is allowed to read the transcript and does not exist.`);
  }
}

if (asked === 0) {
  failures.push(
    "Nothing in the app reads the recordings table, which cannot be right - the client record shows the panel.",
  );
}

if (failures.length) {
  console.error("check-transcript-stays FAILED\n");
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(
  `check-transcript-stays ok — the transcript is read in ${MAY_READ.size} places, all of them the recording itself`,
);
