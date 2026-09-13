/**
 * Reading a real USOR authorization's layout, and matching its number.
 *
 *   node --experimental-strip-types scripts/check-auth-labels.mjs
 *
 * The parser's labels were written before anybody had seen a real
 * authorization, and on the first 16 real ones it read the number off none of
 * them and the start date off none. The layout below mirrors what those forms
 * actually print — the number as "(AUTHNUM …)" mid-line, the dates as
 * "Begin:" and "End:" partway along — with every name and number invented.
 * No client's authorization is in this repository.
 */
import { parseAuthorizationText } from "../lib/authorization-parse.ts";
import { normalizeAuthNumber, authorizationsMentioned } from "../lib/auth-number.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const meta = { pages: 1, scanned: false };

// ── the layout USOR prints ───────────────────────────────────
const usor = [
  "Utah State Office of Rehabilitation",
  "AUTHORIZATION AND INVOICE FOR SERVICE",
  "Vendor: Example Provider (AUTHNUMZ1234567)",
  "Case: 12-34 Begin: 01/02/2025",
  "Line: 01 Unit Number: 1234 End: 06/30/2025",
  "Service: Job Coaching",
  "Rate: $45.00",
].join("\n");

const read = parseAuthorizationText(usor, meta);
const got = (k) => read.fields[k]?.value;

if (got("authNumber") !== "Z1234567") {
  fail(`the number printed as "(AUTHNUMZ1234567)" read as ${got("authNumber") ?? "nothing"}`);
} else {
  ok('the number is read from "(AUTHNUMZ…)", glued to its label mid-line, as USOR prints it');
}

if (got("startDate") !== "2025-01-02") {
  fail(`"Begin: 01/02/2025" read as a start date of ${got("startDate") ?? "nothing"}`);
} else {
  ok('the start date is read from "Begin:" partway along a line');
}

if (got("endDate") !== "2025-06-30") {
  fail(`"End: 06/30/2025" read as an end date of ${got("endDate") ?? "nothing"}`);
} else {
  ok('the end date is read from "End:" partway along a line');
}

// "Unit Number: 1234" is on the same line as the end date. It is not the
// authorization number, and it must not become it.
if (got("authNumber") === "1234") {
  fail('"Unit Number" was taken for the authorization number');
} else {
  ok('a "Unit Number" beside it is not mistaken for the authorization number');
}

const spaced = parseAuthorizationText("Vendor: Example Provider (AUTHNUM Z1234567)", meta);
if (spaced.fields.authNumber?.value !== "Z1234567") {
  fail("the number with a space after its label was not read");
} else {
  ok("and with a space after the label, too");
}

// ── loosened only as far as a bracket ────────────────────────
// A label in the middle of a line still needs a colon or an opening bracket.
// Without that, "OFFICE" inside "UTAH STATE OFFICE OF REHABILITATION" reads as
// an office called "OF REHABILITATION" — which it once did.
const bare = parseAuthorizationText(
  ["UTAH STATE OFFICE OF REHABILITATION", "Vendor Example AUTHNUM Z7654321 on file"].join("\n"),
  meta,
);
if (bare.fields.authNumber) {
  fail("a label with neither a colon nor a bracket before its value was accepted mid-line");
} else if (bare.fields.office) {
  fail(`"OFFICE" inside the agency's name was read as an office: ${bare.fields.office.value}`);
} else {
  ok("mid-line, only a colon or an opening bracket makes a label — nothing looser");
}

// ── numbers compared as the database compares them ───────────
if (normalizeAuthNumber("z-990 0001") !== "Z9900001" || normalizeAuthNumber(null) !== "") {
  fail("authorization numbers are not normalised the way public.normalize_auth_number does it");
} else {
  ok('"z-990 0001" is Z9900001, exactly as the database compares it');
}

const onFile = [
  { id: "a", number: "Z1234567", status: "Open", start_date: null, end_date: null },
  { id: "b", number: "Q7654321", status: "Open", start_date: null, end_date: null },
  { id: "c", number: "Z12", status: "Open", start_date: null, end_date: null },
];

const byRead = authorizationsMentioned("anything", "z 123-4567", onFile);
if (byRead.length !== 1 || byRead[0].id !== "a" || byRead[0].how !== "number read") {
  fail("the number read off the form did not pick out the authorization on file");
} else {
  ok("the number read off the form picks out the authorization on file");
}

const bySplit = authorizationsMentioned("Paying Q 7654321 for March", null, onFile);
if (bySplit.length !== 1 || bySplit[0].id !== "b" || bySplit[0].how !== "number appears") {
  fail("a number on file written with a space in it was not found in the text");
} else {
  ok("a number on file is found in the text even when a space splits it");
}

const embedded = authorizationsMentioned("reference XZ12345678 and Z12 again", null, onFile);
if (embedded.length !== 0) {
  fail(`a number was found inside a longer one, or a too-short number matched: ${embedded.map((m) => m.number)}`);
} else {
  ok("a number inside a longer one is not a match, and numbers too short to be sure of are ignored");
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- AUTHORIZATION LABELS VERIFIED ---");
