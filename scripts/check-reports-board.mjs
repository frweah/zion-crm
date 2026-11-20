/**
 * The reports board, checked where no database is needed (0377).
 *
 *   node scripts/check-reports-board.mjs   (also runs before every build)
 *
 * Six rules, and every one of them is a mistake that was nearly made while
 * the board was being built:
 *
 *   **The service-family map is in two languages now.** `FAMILY_OF` in
 *   lib/report-shape.ts decides which section a line goes under; the board
 *   needs the same answer in SQL, to decide which template a client-month is
 *   owed. Two copies of a fifteen-row map is a map that drifts, so the two
 *   are compared here rather than remembered.
 *
 *   **A template the board offers has to be one of the five.** It is a check
 *   constraint in the database, and a board offering an "Assemble it" button
 *   for a sixth would be a button that always fails.
 *
 *   **Overdue needs `owed`.** Eleven clients hold a coaching authorization,
 *   and the board offers each of them a Job Coaching Update row. Nobody has
 *   asked for one. Without `owed` in the rule the board would have opened
 *   with eleven reports marked overdue that the practice does not owe - the
 *   first version of `overdue` did exactly that, and the number on the tile
 *   was the giveaway.
 *
 *   **A tile is a filter.** The number on it is `rows.filter(t.holds)`, never
 *   a second count, which is what keeps a tile and the rows it filters to the
 *   same arithmetic.
 *
 *   **A chip counts only what the drafter reads.** A text reaches a report
 *   once somebody logged it as a contact and a recording once it was
 *   confirmed, so a chip for either would tell the person compiling the month
 *   that something is in it when it is not (ruling 5).
 *
 *   **An appointment is in a month once.** The calendar sync fills
 *   `calendar_events` from 20 November 2026, and `to_file_confirm` has always
 *   written a contact-log entry for a filed appointment. Both reach a report.
 *   13 of October's 21 appointments were filed, so a redraft would have
 *   listed thirteen of them twice.
 */
import { readFile, readdir } from "node:fs/promises";
import { FAMILY_OF, REPORT_TEMPLATES, reportPeriodUnit } from "../lib/report-shape.ts";
import {
  CLOSED_GROUPS,
  GROUPS,
  TILES,
  canSign,
  collected,
  overdue,
} from "../lib/reports-board-shape.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const read = (p) => readFile(new URL(`../${p}`, import.meta.url), "utf8");

const MIGRATIONS = new URL("../supabase/migrations/", import.meta.url);
const names = (await readdir(MIGRATIONS)).filter((n) => n.endsWith(".sql")).sort();
const files = [];
for (const name of names) {
  files.push({ name, text: await readFile(new URL(name, MIGRATIONS), "utf8") });
}
/** The newest migration that creates something, which is the one in force. */
const newest = (re) => files.filter((f) => re.test(f.text)).at(-1) ?? null;

/** One function's body, from its CREATE to the dollar-quote that ends it. */
function body(text, signature) {
  const at = text.indexOf(signature);
  if (at < 0) return "";
  const open = text.indexOf("as $$", at);
  const close = text.indexOf("$$;", open);
  return open < 0 || close < 0 ? "" : text.slice(open, close);
}

// ── the map is the same map in both languages ────────────────
const familyFile = newest(/function public\.service_family\(/);
if (!familyFile) {
  fail("no migration creates service_family, so the board cannot tell which report a service is owed");
} else {
  const sql = body(familyFile.text, "function public.service_family(");
  const inSql = Object.fromEntries(
    [...sql.matchAll(/when '([^']+)' then '([^']+)'/g)].map((m) => [m[1], m[2]]),
  );
  const wrong = [];
  for (const [service, family] of Object.entries(FAMILY_OF)) {
    if (inSql[service] !== family) {
      wrong.push(`${service} is ${family} in TypeScript and ${inSql[service] ?? "nothing"} in SQL`);
    }
  }
  for (const service of Object.keys(inSql)) {
    if (!(service in FAMILY_OF)) wrong.push(`SQL knows ${service} and lib/report-shape.ts does not`);
  }
  if (wrong.length) fail(`the service families disagree: ${wrong.join("; ")}`);
  else ok(`all ${Object.keys(FAMILY_OF).length} services belong to the same family in TypeScript and in SQL`);
}

// ── a template the board offers is one of the five ───────────
const templateFile = newest(/function public\.report_template_for_family\(/);
if (!templateFile) {
  fail("no migration creates report_template_for_family, so the board offers nothing");
} else {
  const sql = body(templateFile.text, "function public.report_template_for_family(");
  const offered = [...sql.matchAll(/when '([^']+)' then '([^']+)'/g)].map((m) => ({
    family: m[1],
    template: m[2],
  }));
  const listed = REPORT_TEMPLATES.map((t) => t.key);
  const families = [...new Set(Object.values(FAMILY_OF))];
  const invented = offered.filter((o) => !listed.includes(o.template));
  const noSuchFamily = offered.filter((o) => !families.includes(o.family));
  const weekly = offered.filter((o) => reportPeriodUnit(o.template) !== "month");
  if (!offered.length) {
    fail("report_template_for_family offers no template for any family, so no service ever gets its own row");
  } else if (invented.length) {
    fail(`the board offers ${invented.map((o) => o.template).join(", ")}, which the database refuses`);
  } else if (noSuchFamily.length) {
    fail(`the board keys a report off ${noSuchFamily.map((o) => o.family).join(", ")}, which is not a service family`);
  } else if (weekly.length) {
    fail(`${weekly.map((o) => o.template).join(", ")} has a week for a period and cannot be a month's row`);
  } else {
    ok(`${offered.length} service families have a report of their own, and each is one of the five monthly ones`);
  }
}

// ── Overdue reads `owed`, and is not a group ─────────────────
// Run rather than read: a row past its date that nobody asked for is the
// case the board got wrong first.
const row = (over) => ({
  row_key: "x",
  client_id: "c",
  client_name: "ZZ Test",
  client_no: 1,
  counselor: null,
  office: null,
  period: "2026-10-01",
  template: "Job Coaching Update",
  report_id: null,
  status: "Not started",
  writer_id: null,
  writer: null,
  due_on: "2026-11-05",
  days_left: -15,
  signed_at: null,
  sent_at: null,
  sent_to: null,
  owed: over,
  services: [],
  hourly: false,
  notes: 1,
  contacts: 0,
  hours: 0,
  weeks_confirmed: 0,
  weeks_total: 0,
  first_unconfirmed_week: null,
  applications: 0,
  placements: 0,
});
const today = "2026-11-20";

if (GROUPS.includes("Overdue")) {
  fail("Overdue is a group, so a late report leaves the group that says what has been done to it");
} else if (!overdue(row(true), today)) {
  fail("a monthly report a fortnight past its date is not overdue, so the tile counts nothing");
} else if (overdue(row(false), today)) {
  fail("a report nobody asked for counts as overdue, which is eleven lies on the coaching rows");
} else if (!CLOSED_GROUPS.includes("Sent")) {
  fail("Sent is not served folded, so the board opens on the record rather than on the work");
} else {
  ok("Overdue is a flag and a tile, reads `owed`, and Sent is served folded");
}

// ── a tile is a filter, counted once ─────────────────────────
const board = await read("app/(app)/client-reports/reports-board.tsx");
const tileBlock = board.slice(board.indexOf('className="tiles'), board.indexOf("</div>", board.indexOf('className="tiles')));
if (!tileBlock) {
  fail("the board draws no tiles");
} else if (!/rows\.filter\(\(x\) => t\.holds\(x, today\)\)\.length/.test(tileBlock)) {
  fail("a tile's number is not rows.filter(t.holds), so it can disagree with the rows it filters to");
} else if (!TILES.every((t) => typeof t.holds === "function")) {
  fail("a tile has no question to ask of a row");
} else {
  ok(`all ${TILES.length} tiles count the rows they filter to, with one question each`);
}

// ── a chip counts only what the drafter reads ────────────────
const ALLOWED = ["notes", "contacts", "hours", "weeks", "applications", "placements"];
const full = {
  ...row(true),
  notes: 3,
  contacts: 4,
  hours: 2.5,
  weeks_confirmed: 1,
  weeks_total: 2,
  applications: 1,
  placements: 1,
};
const keys = collected(full).map((c) => c.key);
const extra = keys.filter((k) => !ALLOWED.includes(k));
const red = collected({ ...row(true), notes: 0, hourly: true, hours: 0, weeks_total: 2, weeks_confirmed: 0 })
  .filter((c) => c.bad)
  .map((c) => c.key)
  .sort();
if (extra.length) {
  fail(`a chip counts ${extra.join(", ")}, which no report carries`);
} else if (red.join(",") !== "hours,notes,weeks") {
  fail(`the red chips are ${red.join(", ") || "none"} and the owner named no notes, no hours on an hourly service, and a week nobody confirmed`);
} else if (collected({ ...row(true), hourly: false, hours: 0 }).some((c) => c.key === "hours")) {
  fail("a client with no hourly service is asked for hours anyway");
} else {
  ok("a chip counts only what the drafter reads, and the three red ones are the three the owner named");
}

// ── signing is narrower than writing ─────────────────────────
const mine = { ...row(true), writer_id: "me" };
if (!canSign(mine, { id: "me", role: "Job Coach" })) {
  fail("the writer of a report cannot sign their own");
} else if (!canSign(mine, { id: "other", role: "Reports" })) {
  fail("Reports cannot sign a report somebody else wrote");
} else if (!canSign(mine, { id: "other", role: "Admin" })) {
  fail("Admin cannot sign a report somebody else wrote");
} else if (canSign(mine, { id: "other", role: "Job Coach" })) {
  fail("anybody can sign anybody's report, so the signature says nothing");
} else {
  ok("a report is signed by its writer, by Reports or by Admin, and by nobody else");
}

// ── an appointment is in a month once ────────────────────────
const period = await read("lib/report-period.ts");
const loop = period.slice(period.indexOf("for (const ev of eventsResult.data"));
const filed = period.slice(period.indexOf("const filedAppointments"), period.indexOf("for (const ev of eventsResult.data"));
if (!filed.includes('c.method === "Appointment"')) {
  fail("the drafter does not look for appointments somebody already filed as contacts");
} else if (!/\$\{c\.date\}\|/.test(filed) || !/topic/.test(filed)) {
  fail("the filed appointments are not keyed on the day and the title the filing wrote");
} else if (!/if \(filedAppointments\.has\(/.test(loop)) {
  fail("the appointment loop does not skip the ones already filed, so a filed appointment is in the month twice");
} else if (loop.indexOf("filedAppointments.has(") > loop.indexOf('kind: "appointment"')) {
  fail("the appointment line is written before the check that it is not already there");
} else {
  ok("an appointment somebody filed is in the month once, as the contact they filed");
}

// ── and the sync writes a row only when it is sure ───────────
const sync = await read("lib/sync.ts");
const match = sync.slice(sync.indexOf("const namedInEvent"), sync.indexOf("// ── mail"));
if (!match.includes("clients_named_in")) {
  fail("the calendar sync does not ask which client an event names, so it is back to a tag nobody types");
} else if (!/ids\.length === 1 \? ids\[0\] : null/.test(match)) {
  fail("the calendar sync takes one of several matching clients, which files an appointment against a guess");
} else if (!/kind: "Other"/.test(sync)) {
  fail("an event pulled from Outlook is not given a kind, so it lands on the record as a coaching visit");
} else {
  ok("the calendar sync writes a row only where exactly one Active client is named, and says it is Other");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- REPORTS BOARD VERIFIED ---");
