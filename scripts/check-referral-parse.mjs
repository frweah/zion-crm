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

/**
 * A real DWS-USOR 94, line for line, with the names replaced.
 *
 * This one is here because it got through. Everything above puts the fields in
 * the first few lines with nothing around them, and a real 94 opens with three
 * lines of USOR's own instructions, a column heading, and only then the boxes.
 * Read on 23 October it created a client called "The assessment is due", whose
 * counselor was "Referral Page" and whose referring office was
 * "Observations:", and then a poll every fifteen minutes wrote 549 contact-log
 * rows onto it. The name was on the form, correctly labelled, three lines
 * below the sentence that was read instead.
 *
 * The prose is USOR's and is kept exactly - it is the prose that did it. The
 * client, counselor and address are invented, because a real one does not go
 * in a repository.
 */
const wholeForm94 = `
DWS-USOR 94 State of Utah
Rev. 07/2026 Department of Workforce Services
WORK STRATEGY ASSESSMENT
This form is to be completed by the VR Counselor, Community Rehabilitation Program (CRP)
Provider, and the client. The assessment is due when the team meets to review the results, agree to
goals, and sign the assessment.
Counselor Referral Page
Client Name: ZZ Testperson Quayle
Address: 1 ZQ Example Street
City: Ogden State: Utah ZIP: 84401
CRP Referring to: Zion Vocational Rehabilitation
Client Phone: NA Client Cell: (801) 555-0142
Guardianship: Yes No If yes, Parent/Guardian name and phone:
Describe the following as it applies to client:
Interpersonal skills How the client reacts to criticism
Worksite Simulation Location:
Observations:
Client Signature: Date:
CRP Signature: Date:
VR Counselor Signature: Date:
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

// ── the whole form, not the first few lines of it ────────────
//
// Four assertions rather than one, because the fault produced four wrong
// answers and a check that only asked about the name would have let the office
// through. Each is named so a failure says which half of the guard went.
{
  const r = parseReferralText(wholeForm94);
  const name = r.fields.clientName?.value ?? "";
  const counselor = r.fields.counselor?.value ?? "";
  const office = r.fields.office?.value ?? "";

  if (name !== "ZZ Testperson Quayle") {
    fail(`the name on a whole USOR 94 read as ${JSON.stringify(name)} rather than the Client Name field`);
  } else {
    ok("the name comes off the Client Name box and not the instructions above it");
  }

  // "Provider, and the client. The assessment is due when the team meets" -
  // the sentence that became a client.
  if (/assessment|provider|complete/i.test(name)) {
    fail(`the client name was read out of the form's instructions: ${JSON.stringify(name)}`);
  } else {
    ok("a sentence containing the word client is not a client name");
  }

  // "Counselor Referral Page" is a column heading. The form has no counselor
  // box at all, and nothing is better than something invented.
  if (/referral|page/i.test(counselor)) {
    fail(`the counselor was read off a column heading: ${JSON.stringify(counselor)}`);
  } else {
    ok("a column heading is not a counselor");
  }

  // "Worksite Simulation Location:" with "Observations:" under it.
  if (office.endsWith(":") || /observation/i.test(office)) {
    fail(`the office was read off a form heading: ${JSON.stringify(office)}`);
  } else {
    ok("a line ending in a colon is naming a box, not filling one");
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
