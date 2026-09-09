/**
 * The quick-add "+", checked.
 *
 *   node --experimental-strip-types scripts/check-quick-add.mjs
 *
 * The whole safety of a second, faster way in is that it is not a second set
 * of rules: every kind hands to the action the full screen uses. The failure
 * this guards against is somebody later adding a kind here with its own insert
 * — quicker to write, and quietly outside the checks about who may edit a
 * client record, what a task needs, and whether an employer already exists.
 */
import { readFile } from "node:fs/promises";
import { QUICK_KINDS, kindsForRole } from "../lib/quick-add.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const source = await readFile(
  new URL("../app/(app)/quick-add-actions.ts", import.meta.url),
  "utf8",
);

// ── the six the brief asks for ───────────────────────────────
const keys = QUICK_KINDS.map((k) => k.key);
const expected = ["note", "task", "job", "interview", "placement", "session"];
if (keys.join(",") !== expected.join(",")) {
  fail(`the "+" offers ${keys.join(", ")}, not ${expected.join(", ")}`);
} else {
  ok("note, task, job, interview, placement and work session");
}

// ── each one goes somewhere ──────────────────────────────────
for (const k of keys) {
  // "session" is the fallthrough at the end of the dispatch.
  if (k !== "session" && !source.includes(`what === "${k}"`)) {
    fail(`"${k}" is offered and never handled`);
  }
}
if (!problems.length) ok("every kind offered is a kind handled");

// ── and goes through the action the screen uses ──────────────
const delegates = ["addNote", "addTask", "addClientJob", "updateClientJob", "addPlacement", "logSession"];
for (const d of delegates) {
  if (!new RegExp(`\\breturn ${d}\\(|\\b${d}\\(`).test(source)) {
    fail(`nothing calls ${d} — a kind is writing its own way in`);
  }
}
if (!problems.length) ok("each kind hands to the action its full screen uses");

// ── and writes nothing itself ────────────────────────────────
// One read is allowed and named: the interview kind reads the job back so the
// whole-row update does not blank fields the modal never asked for.
const writes = [...source.matchAll(/\.(insert|update|upsert|delete)\(/g)].map((m) => m[1]);
if (writes.length) {
  fail(`quick-add-actions.ts writes to the database itself (${writes.join(", ")})`);
} else {
  ok("it writes nothing of its own — no second set of rules to keep in step");
}

const reads = [...source.matchAll(/\.from\("(\w+)"\)/g)].map((m) => m[1]).sort();
const allowedReads = ["client_job_history", "clients", "employers", "lead_matches"];
const unexpected = [...new Set(reads)].filter((r) => !allowedReads.includes(r));
if (unexpected.length) {
  fail(`it reads ${unexpected.join(", ")}, which the modal has no use for`);
} else {
  ok("it reads only the lists the modal offers, and the job it is amending");
}

// ── Billing can log their hours and nothing else ─────────────
const cases = [
  ["Admin", 6],
  ["Job Search", 6],
  ["Reports", 6],
  ["Billing", 1],
];
for (const [role, count] of cases) {
  const got = kindsForRole(role);
  if (got.length !== count) {
    fail(`${role} is offered ${got.length} kinds (${got.join(", ")}), expected ${count}`);
  }
}
if (kindsForRole("Billing").join(",") !== "session") {
  fail(`Billing is offered ${kindsForRole("Billing").join(", ")} rather than only a work session`);
} else {
  ok("Billing gets the work session and nothing that edits a client record");
}

if (kindsForRole("Nonsense").length !== 1) {
  fail("an unknown role is offered more than a work session");
} else {
  ok("an unknown role falls to the least it could be given, not the most");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- QUICK ADD VERIFIED ---");
