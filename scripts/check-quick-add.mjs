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
 *
 * It was written when the "+" offered six kinds and asserted that it offered
 * exactly those six, by name, and that each role was offered a particular
 * number of them. Three kinds were added over the following month - hours, an
 * authorization, a file - and every one of those assertions went stale at
 * once. Because it is not in `prebuild` nobody found out, so by 26 Oct 2026
 * the check that guards the "+" had been failing on ten counts for weeks.
 *
 * So it now asks the rules rather than the roster: a kind either dispatches or
 * hands over, a role is offered a kind only if it may do that thing, and both
 * lists come from the code that decides them. It is in `prebuild`, which is
 * the only reason to believe any of it tomorrow.
 */
import { readFile } from "node:fs/promises";
import { QUICK_KINDS, kindsForRole } from "../lib/quick-add.ts";
import { CAN_EDIT_CLIENTS, CAN_LOG_HOURS } from "../lib/constants.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const source = await readFile(
  new URL("../app/(app)/quick-add-actions.ts", import.meta.url),
  "utf8",
);
const modal = await readFile(new URL("../app/(app)/quick-add.tsx", import.meta.url), "utf8");

const keys = QUICK_KINDS.map((k) => k.key);

/**
 * The two kinds that are not a quickAdd() row.
 *
 * A file's bytes go from the browser straight to storage, and an
 * authorization finds its own client and prices itself off the rate schedule.
 * Both hand over to the form their full screen uses, which is the same rule as
 * everything else here - it just arrives as a component rather than a call.
 */
const HANDS_OVER = { file: "AddFileForm", authorization: "AddAuthorizationForm" };

// ── every kind goes somewhere ────────────────────────────────
for (const k of keys) {
  if (k in HANDS_OVER) {
    if (!modal.includes(`<${HANDS_OVER[k]}`)) {
      fail(`"${k}" hands over to ${HANDS_OVER[k]}, which the modal does not render`);
    }
    continue;
  }
  // "session" is the fallthrough at the end of the dispatch.
  if (k !== "session" && !source.includes(`what === "${k}"`)) {
    fail(`"${k}" is offered and never handled`);
  }
}
if (!problems.length) ok("every kind offered either dispatches or hands over to its own form");

// ── and goes through the action the screen uses ──────────────
const delegates = ["addNote", "addTask", "addClientJob", "updateClientJob", "addPlacement", "logSession", "logServiceEntry"];
for (const d of delegates) {
  if (!new RegExp(`\\b${d}\\(`).test(source)) {
    fail(`nothing calls ${d} — a kind is writing its own way in`);
  }
}
if (!problems.length) ok("each kind hands to the action its full screen uses");

// ── and writes nothing itself ────────────────────────────────
const writes = [...source.matchAll(/\.(insert|update|upsert|delete)\(/g)].map((m) => m[1]);
if (writes.length) {
  fail(`quick-add-actions.ts writes to the database itself (${writes.join(", ")})`);
} else {
  ok("it writes nothing of its own — no second set of rules to keep in step");
}

const reads = [...source.matchAll(/\.from\("(\w+)"\)/g)].map((m) => m[1]);
const allowedReads = [
  "client_job_history",
  "clients",
  "employers",
  "lead_matches",
  "work_categories",
  // The lists the later kinds offer: what hours may go against, and the
  // document types with which of them start restricted (0203).
  "authorizations",
  "client_file_categories",
];
const unexpected = [...new Set(reads)].filter((r) => !allowedReads.includes(r));
if (unexpected.length) {
  fail(`it reads ${unexpected.join(", ")}, which the modal has no use for`);
} else {
  ok("it reads only the lists the modal offers, and the job it is amending");
}

/**
 * ── and offers each role only what that role may do ─────────
 *
 * The rule, not a count. A kind that edits a client record goes to the roles
 * that may edit client records; billable hours go to whoever may log them;
 * entering an authorization is Admin's and Billing's. A work session and a
 * document are everybody's.
 */
const EDITS_A_CLIENT = ["note", "task", "job", "interview", "placement"];
const ROLES = ["Admin", "Billing", "Job Search", "Reports", "Job Coach", "Nonsense"];
for (const role of ROLES) {
  const got = kindsForRole(role);
  const may = {
    session: true,
    file: true,
    hours: role === "Admin" || role === "Billing" || CAN_LOG_HOURS.includes(role),
    authorization: role === "Admin" || role === "Billing",
  };
  for (const k of got) {
    const allowed = EDITS_A_CLIENT.includes(k) ? CAN_EDIT_CLIENTS.includes(role) : may[k];
    if (!allowed) fail(`${role} is offered "${k}", which that role may not do`);
  }
  for (const k of keys) {
    const should = EDITS_A_CLIENT.includes(k) ? CAN_EDIT_CLIENTS.includes(role) : may[k];
    if (should && !got.includes(k)) fail(`${role} may ${k} and is not offered it`);
  }
  if (!got.includes("session") || !got.includes("file")) {
    fail(`${role} is not offered a work session and a document, which are everybody's`);
  }
}
if (!problems.length) ok("each role is offered exactly the kinds that role may use");

// A role nobody has heard of falls to the least it could be given.
const unknown = kindsForRole("Nonsense");
if (unknown.some((k) => EDITS_A_CLIENT.includes(k) || k === "hours" || k === "authorization")) {
  fail(`an unknown role is offered ${unknown.join(", ")} rather than the least it could be`);
} else {
  ok("an unknown role falls to the least it could be given, not the most");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- QUICK ADD VERIFIED ---");
