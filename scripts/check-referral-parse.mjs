/**
 * What a referral form says, read off its text.
 *
 *   node scripts/check-referral-parse.mjs
 *
 * A referral is the one document that may create a client (Intake Automation
 * Brief, Rule 1), so a field read off the wrong line does not produce a wrong
 * value on a screen somebody checks - it produces a client. The cases here are
 * mostly the ways that could happen.
 */
import { parseReferralText } from "../lib/referral-parse.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const usor94 = `
UTAH STATE OFFICE OF REHABILITATION
DWS-USOR 94  VOCATIONAL REHABILITATION REFERRAL
Client Name: Jordan Sample
Phone: (801) 555-0142
Counselor: Dana Lee
Office: Salt Lake City Office
Referral Date: 03/04/2026
`;

// The same form with the labels above the boxes, which is how it prints when
// the fields are filled in rather than typed on the line.
const labelsAbove = `
VOCATIONAL REHABILITATION REFERRAL
Client Name
Marion Quayle
Counselor
Dana Lee
Referral Date
11/18/2026
`;

const noName = `
VOCATIONAL REHABILITATION REFERRAL
Counselor: Dana Lee
Office: Ogden
Referral Date: 03/04/2026
`;

// ── the fields come off the form ─────────────────────────────
{
  const r = parseReferralText(usor94);
  const got = Object.fromEntries(Object.entries(r.fields).map(([k, v]) => [k, v.value]));
  const want = {
    clientName: "Jordan Sample",
    counselor: "Dana Lee",
    office: "Salt Lake City",
    referralDate: "2026-03-04",
    phone: "(801) 555-0142",
  };
  const wrong = Object.entries(want).filter(([k, v]) => got[k] !== v);
  if (wrong.length) {
    for (const [k, v] of wrong) fail(`${k} read as ${JSON.stringify(got[k])}, expected ${JSON.stringify(v)}`);
  } else {
    ok("name, counselor, office, date and phone come off a USOR 94");
  }
}

// ── the office is not read out of the letterhead ─────────────
//
// "UTAH STATE OFFICE OF REHABILITATION" contains the word OFFICE, and the
// authorization parser read the office as "OF REHABILITATION" the first time
// it was run against real forms. The same trap is here, so the same case is.
{
  const r = parseReferralText(usor94);
  const office = r.fields.office?.value ?? "";
  if (/rehabilitation/i.test(office)) {
    fail(`the office was read out of the letterhead: ${JSON.stringify(office)}`);
  } else {
    ok("the office is not read out of \"UTAH STATE OFFICE OF REHABILITATION\"");
  }
}

// ── a label above its box ────────────────────────────────────
{
  const r = parseReferralText(labelsAbove);
  if (r.fields.clientName?.value !== "Marion Quayle") {
    fail(`a label above its box gave ${JSON.stringify(r.fields.clientName?.value)}`);
  } else if (r.fields.counselor?.value !== "Dana Lee") {
    fail(`the counselor above its box gave ${JSON.stringify(r.fields.counselor?.value)}`);
  } else if (r.fields.referralDate?.value !== "2026-11-18") {
    fail(`the date above its box gave ${JSON.stringify(r.fields.referralDate?.value)}`);
  } else {
    ok("a form with its labels above the boxes reads the same");
  }
}

// ── no name is not a client ──────────────────────────────────
//
// The case that matters most: nothing may invent one. A referral with no name
// read on it is reported missing, and the rule refuses to file it.
{
  const r = parseReferralText(noName);
  if (!r.missing.includes("clientName")) {
    fail(`a referral with no client name read ${JSON.stringify(r.fields.clientName?.value)} as the name`);
  } else {
    ok("a referral with no client name on it says so, rather than inventing one");
  }
}

// ── every field says where it came from ──────────────────────
{
  const r = parseReferralText(usor94);
  const unsourced = Object.entries(r.fields).filter(([, v]) => !v.source || !v.rule);
  if (unsourced.length) {
    fail(`read without saying where from: ${unsourced.map(([k]) => k).join(", ")}`);
  } else {
    ok("every field read says which line and which rule it came from");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- REFERRAL PARSER VERIFIED ---");
