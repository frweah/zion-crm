/**
 * The document classifier, checked.
 *
 *   node --experimental-strip-types scripts/check-classify.mjs
 *
 * Getting this wrong is cheap in one direction and expensive in the other. A
 * warrant filed as "Other" is a document somebody has to go and find. An
 * invoice marked paid because a page mentioned a number is money the practice
 * believes it has. So most of what follows is about the expensive direction:
 * that nothing is classified as a warrant or an authorization on a weak
 * signal, and that the amounts pulled off a warrant are amounts.
 */
import { classifyDocument } from "../lib/classify-document.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const pad = (s) => s + "\n" + "filler text ".repeat(20);

// ── the four kinds ───────────────────────────────────────────
const authorization = pad(`
UTAH STATE OFFICE OF REHABILITATION
AUTHORIZATION FOR SERVICES
Authorization #: VR-2026-004417
Client Name: Jordan Sample
Service Type: Job Coaching
Total Hours: 40
Rate: $45.00
`);

const warrant = pad(`
STATE OF UTAH REMITTANCE ADVICE
Warrant #: 40219883
Vendor: ZION VOCATIONAL REHABILITATION CENTER
Invoice 2026-114   $1,350.00
Invoice 2026-115   $560.00
Total paid $1,910.00
`);

const usorForm = pad(`
DWS-USOR 95
Job Coaching Monthly Report
Client: Jordan Sample
Month: March 2026
`);

const letter = pad(`
Dear Provider
Thank you for your continued partnership with the Utah State Office of
Rehabilitation. Please find enclosed our updated provider handbook.
`);

const cases = [
  ["an authorization", authorization, "Authorization"],
  ["a remittance advice", warrant, "Warrant"],
  ["a single USOR form", usorForm, "USOR form"],
  ["a covering letter", letter, "Other"],
];

for (const [what, text, expected] of cases) {
  const got = classifyDocument(text);
  if (got.kind !== expected) {
    fail(`${what} classified as "${got.kind}", expected "${expected}" (${got.reason})`);
  }
}
if (!problems.length) ok("an authorization, a warrant, a USOR form and a letter are told apart");

// ── which of them starts a case ──────────────────────────────
//
// A referral is the one document that may create a client (Intake Automation
// Brief, Rule 1), so the question "is this a referral" is asked of the same
// classifier rather than a second one - and the cases that matter are the
// ones where the answer must be no. A monthly report has the word "referral"
// nowhere near it but a USOR number that is not 94 or 98; an authorization
// for a client who was referred says "referral" in its own text. Either read
// as a referral would create a client from a document that is not one.
const referral94 = pad(`
DWS-USOR 94
VOCATIONAL REHABILITATION REFERRAL
Client Name: Jordan Sample
Counselor: Dana Lee
Office: Salt Lake City
Referral Date: 03/04/2026
`);

const usor98 = pad(`
USOR 98
Counselor response - services may begin
Client: Jordan Sample
`);

const wsaReferral = pad(`
WSA REFERRAL FOR SERVICES
Utah State Office of Rehabilitation
Client Name: Jordan Sample
Counselor: Dana Lee
Referral Date: 03/04/2026
`);

const authAfterReferral = pad(`
UTAH STATE OFFICE OF REHABILITATION
AUTHORIZATION FOR SERVICES
Authorization #: VR-2026-004418
Client Name: Jordan Sample
Service Type: Job Placement
This authorization follows the referral dated 03/04/2026.
`);

const referralCases = [
  ["a USOR 94", referral94, true],
  ["a USOR 98", usor98, true],
  ["a WSA referral naming no form", wsaReferral, true],
  ["a USOR 95 monthly report", usorForm, false],
  ["an authorization that mentions the referral", authAfterReferral, false],
  ["a covering letter", letter, false],
  ["a remittance advice", warrant, false],
];
const referralWrong = [];
for (const [what, text, expected] of referralCases) {
  const got = classifyDocument(text);
  if (Boolean(got.referral) !== expected) {
    referralWrong.push(
      `${what} reads as ${got.referral ? "a referral" : "not a referral"} (${got.kind}: ${got.reason})`,
    );
  }
}
if (referralWrong.length) {
  for (const w of referralWrong) fail(`the referral rule is wrong: ${w}`);
} else {
  ok(`all ${referralCases.length} cases agree on what starts a case and what does not`);
}

// ── a warrant listing authorizations is still a warrant ──────
// This is the case that decides the rule order. A remittance advice names the
// authorizations it pays, so it carries both sets of marks; what matters
// about it is the payment.
const both = pad(`
REMITTANCE ADVICE
Warrant #: 40219884
Paying Authorization #: VR-2026-004417 authorized units 40
Amount $1,800.00
`);
if (classifyDocument(both).kind !== "Warrant") {
  fail("a remittance advice naming an authorization was classified as the authorization");
} else {
  ok("a warrant that lists the authorizations it pays is still a warrant");
}

// ── a document naming several forms is not one of them ───────
const index = pad(`
Provider forms index
DWS-USOR 93, DWS-USOR 95 and DWS-USOR 148 are attached for your records.
`);
const indexed = classifyDocument(index);
if (indexed.kind !== "Other") {
  fail(`a document naming three USOR forms was classified as "${indexed.kind}"`);
} else {
  ok("a document naming three USOR forms is an index, not a form");
}

// ── a USOR form with an "Authorization #" box is still the form ──
// USOR 95 and 96 carry the authorization number in a box. The first real
// backfill called nine of them authorizations; confirming one would copy a
// rate onto a client's record off a monthly report.
const usor95 = pad(`
DWS - USOR 95
State of Utah
Job Coaching Monthly Report
Authorization #: Z1234567
`);
const u95 = classifyDocument(usor95);
if (u95.kind !== "USOR form") {
  fail(`a USOR 95 with an authorization number box was classified as "${u95.kind}" (${u95.reason})`);
} else {
  ok("a USOR 95 with an \"Authorization #\" box is a USOR form, not an authorization");
}

// And USOR's own authorization, by the title it prints.
const usorAuth = pad(`
Utah State Office of Rehabilitation
AUTHORIZATION AND INVOICE FOR SERVICE
Vendor: Example Provider (AUTHNUM Z1234567)
`);
if (classifyDocument(usorAuth).kind !== "Authorization") {
  fail(`USOR's authorization form was classified as "${classifyDocument(usorAuth).kind}"`);
} else {
  ok("USOR's own authorization is recognised by the title it prints");
}

// ── a scan is named, not guessed at ──────────────────────────
const scanned = classifyDocument("   \n  \n ");
if (scanned.kind !== "Unreadable") {
  fail(`an empty document was classified as "${scanned.kind}"`);
} else {
  ok("a file with no text is Unreadable — it is not evidence of anything");
}

// ── the amounts off a warrant ────────────────────────────────
const amounts = classifyDocument(warrant).amounts ?? [];
for (const expected of [1350, 560, 1910]) {
  if (!amounts.includes(expected)) fail(`the warrant's $${expected} was not picked up`);
}
if (!problems.length) ok("every amount on a warrant is picked up, for matching against invoices");

// A stray dollar sign in front of a page number is still read as an amount —
// there is no way to tell one from a genuine $3.00 — but a figure under a
// dollar is never a payment, and the real amount has to survive the filter.
const noisy = pad(`
REMITTANCE ADVICE
Warrant #: 1
Page $1 of $3
Total $0.50 processing
Amount $980.00
`);
const noisyAmounts = classifyDocument(noisy).amounts ?? [];
if (noisyAmounts.includes(0.5)) {
  fail("half a dollar was treated as a payment amount");
} else if (!noisyAmounts.includes(980)) {
  fail("the real amount was lost while filtering the noise");
} else {
  ok("sub-dollar figures are not amounts, and the real one survives the filtering");
}

// ── the warrant number ───────────────────────────────────────
if (classifyDocument(warrant).warrantNumber !== "40219883") {
  fail(`the warrant number read as ${classifyDocument(warrant).warrantNumber}`);
} else {
  ok("the warrant number is read off it, so a payment can be traced back");
}

// ── every answer says which rule gave it ─────────────────────
for (const [what, text] of cases) {
  if (!classifyDocument(text).reason) fail(`${what} came back with no reason`);
}
ok("every classification says which rule decided it");

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- DOCUMENT CLASSIFIER VERIFIED ---");
