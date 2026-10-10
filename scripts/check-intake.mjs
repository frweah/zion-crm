/**
 * The intake, where it cannot be checked from the database.
 *
 *   node scripts/check-intake.mjs
 *
 * verify_the_intake.sql holds the rules - what a referral does, what an
 * authorization does, who is told. Three things are not in the database and so
 * are here:
 *
 *   Which senders are acted on. The route decides that before anything is
 *   read, so no row exists to test.
 *
 *   That there is one reader, one classifier and one OCR path. The brief says
 *   so in as many words, and the way that rule breaks is somebody adding a
 *   second one in a hurry rather than changing the first.
 *
 *   That the words of a notification are written once. The route sends the
 *   email; the sentence comes from the database with the notification, so the
 *   bell, My day and the mail cannot drift apart.
 */
import { readFileSync } from "node:fs";
import { isFromUtahGov, INTAKE_MAILBOX } from "../lib/intake-source.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const src = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");
const route = src("app/api/cron/intake/route.ts");
// The reading of the mailbox and the deciding live either side of a boundary
// (lib/intake-mail.ts holds the token, the route holds the database), so each
// rule below is asked of the file that is responsible for it.
const reader = src("lib/intake-mail.ts");
const chase = src("app/api/cron/chase/route.ts");

// ── whose mail is acted on ───────────────────────────────────
//
// The noes are the point. A referral is the one document that creates a
// client, so every cheap way of looking like a counselor is tried here.
const SENDERS = [
  ["dana.lee@utah.gov", true],
  ["DANA.LEE@UTAH.GOV", true],
  ["caseworker@dws.utah.gov", true],
  ["referrals@usor.utah.gov", true],
  ["  dana@utah.gov  ", true],
  // Not Utah, however much it looks it.
  ["dana@utah.gov.example.com", false],
  ["dana@notutah.gov", false],
  ["dana@utah.gov.co", false],
  ["utah.gov@gmail.com", false],
  ["dana@utahgov", false],
  ["dana@state.ut.us", false],
  ["", false],
  [null, false],
];
const wrong = SENDERS.filter(([address, expected]) => isFromUtahGov(address) !== expected);
if (wrong.length) {
  for (const [address] of wrong) {
    fail(`the sender rule is wrong about ${JSON.stringify(address)} (it says ${isFromUtahGov(address)})`);
  }
} else {
  ok(`all ${SENDERS.length} sender cases are decided right, sub-domains in and look-alikes out`);
}

// ── and it is the route that asks ────────────────────────────
if (!reader.includes("isFromUtahGov(")) {
  fail("the intake does not ask isFromUtahGov, so the cases above test nothing it uses");
} else if (!reader.includes('handler.skipped(message, "not utah.gov"')) {
  fail("a sender that is not utah.gov is not left alone and logged as skipped");
} else if (!/p_decision: decision/.test(route)) {
  fail("the skip is not recorded, so nobody can find out whether the email arrived");
} else {
  ok("every message is asked that question, and the ones left alone are logged");
}

// ── one mailbox ──────────────────────────────────────────────
if (!route.includes("INTAKE_MAILBOX")) {
  fail("the intake route names its own mailbox instead of reading the one definition");
} else if (!new RegExp(`ilike\\("microsoft_email", INTAKE_MAILBOX\\)`).test(route)) {
  fail(`the route does not narrow the connection to ${INTAKE_MAILBOX}, so it could read a personal inbox`);
} else {
  ok(`only ${INTAKE_MAILBOX} is read - not whichever mailboxes happen to be connected`);
}

// ── one reader, one classifier, one OCR path ─────────────────
{
  const ownReader = [
    [/extractPdfText\(/, "reads a PDF itself instead of through lib/read-document"],
    [/pdfjs|pdf-parse|getDocument\(/, "loads a PDF library of its own"],
    [/AUTHORIZATION_MARKS|WARRANT_MARKS|classify[A-Za-z]*\s*=\s*\(/, "classifies documents itself"],
    [/tesseract|Tesseract|ocr_text_b64/, "has an OCR path of its own"],
  ].filter(([re]) => re.test(route));

  if (ownReader.length) {
    for (const [, what] of ownReader) fail(`the intake route ${what} — the brief asks for one of each`);
  } else if (!route.includes('from "@/lib/read-document"')) {
    fail("the intake route does not use the one reader (lib/read-document)");
  } else if (!route.includes('from "@/lib/classify-document"')) {
    fail("the intake route does not use the one classifier (lib/classify-document)");
  } else {
    ok("the route reads and classifies through the one reader and the one classifier, and has no OCR path of its own");
  }
}

// ── the agent and the intake call the same reader ────────────
{
  const agent = src("app/api/agent/file/route.ts");
  const reader = src("lib/read-document.ts");
  if (!agent.includes('from "@/lib/read-document"')) {
    fail("the agent route no longer uses the shared reader, so there are two readings of a PDF");
  } else if (!/export async function readDocument\(/.test(reader)) {
    fail("lib/read-document does not export readDocument");
  } else {
    ok("the agent and the intake read a PDF the same way, through one function");
  }
}

// ── the words are written once ───────────────────────────────
//
// The route may say where something came from; it may not compose the sentence
// a person reads. Those sentences are built in the database beside the
// notification and the My day item, which is what stops the three drifting.
{
  const invented = [
    [/New referral:/, "writes the referral notification's words"],
    [/Referral re-sent/, "writes the re-send notification's words"],
    [/Authorization .*received for/, "writes the authorization notification's words"],
    [/Initiate contact with/, "writes the My day item's words"],
  ].filter(([re]) => re.test(route));

  if (invented.length) {
    for (const [, what] of invented) {
      fail(`the intake route ${what} — one function builds all three from one message`);
    }
  } else if (!/who\.message/.test(route)) {
    fail("the route does not send the words the database returned, so the email can say something else");
  } else {
    ok("every sentence a person reads is written once, in the database, and the route only carries it");
  }
}

// ── the reply is claimed, not decided ────────────────────────
{
  if (!/intake_record_mail/.test(route)) {
    fail("the route does not record what it did with each message");
  } else if (!/return \{ reply: filed\.reply \};/.test(route)) {
    fail("the route does not pass the database's answer back, so the reply is decided locally");
  } else if (!/p_reply: filed\.reply/.test(route)) {
    fail("the database is not asked to claim the reply, so two polls could both thank the counselor");
  } else if (!reader.includes("if (reply) {")) {
    fail("the mail side replies without being told to");
  } else if (!reader.includes('export const THANKS = "Received, thank you.";')) {
    fail("the reply to the counselor is not the sentence the brief specifies");
  } else {
    ok('the reply is "Received, thank you.", sent only when the database says this run claimed it');
  }
}

// ── chasing sends what the rules say, and nothing else ──────
//
// Rule 6 emails the counselor; Rule 7 emails nobody and gives Margaret the
// draft. The failure to guard against is the chase route writing its own
// words, which would put the practice's voice in two places, or Rule 7
// quietly growing a send.
{
  const invented = [
    [/we received .*referral/i, "writes the nudge's words"],
    [/wanted to check whether/i, "writes the nudge's words"],
    [/Could we arrange a renewal/i, "writes the renewal request's words"],
  ].filter(([re]) => re.test(chase));

  if (invented.length) {
    for (const [, what] of invented) {
      fail(`the chase route ${what} - they belong beside the rule, in the database`);
    }
  } else if (!/w\.body/.test(chase)) {
    fail("the chase route does not send the words the rule returned");
  } else if (!/sendReferralNudge\(/.test(chase)) {
    fail("the chase route does not send the nudge through the one automated sender");
  } else {
    ok("the chase route carries the words the rules wrote and composes none of its own");
  }

  // Rule 7 is Margaret's to send. The only Graph send in this route is the
  // Rule 6 nudge; anything else would be the renewal going out by itself.
  const graphSends = (chase.match(/sendReferralNudge\(|sendNew\(|replyOwn\(/g) ?? []).length;
  if (graphSends !== 1) {
    fail(`the chase route makes ${graphSends} outbound mail call(s); Rule 6's nudge is the only one`);
  } else if (!/record_referral_nudge/.test(chase)) {
    fail("the nudge is not claimed before it is sent, so a second run could send it again");
  } else if (!/dry/.test(chase)) {
    fail("the chase route cannot be asked what it would do without doing it");
  } else {
    ok("Rule 6's nudge is the one thing sent, claimed before sending, and the run can be tried dry");
  }
}

// ── a scan is decided by the same rules, later ──────────────
//
// The brief's Timing section has two halves and only the first needed no code:
// a scan is stored with no text, which is what /api/agent/ocr-wanted looks
// for. The second - "run the rules when text is available" - is a second place
// the rules are asked from, which makes one copy of them the thing to guard.
{
  const asks = (route.match(/askTheRules\(/g) ?? []).length;
  const direct = (route.match(/rpc\("intake_(referral|authorization|other)"/g) ?? []).length;

  if (!/intake_scans_now_readable/.test(route)) {
    fail("the intake never looks again at a scan the agent has since read, so a scanned referral is lost");
  } else if (asks < 2) {
    fail(`the rules are asked from ${asks} place(s); a scan read later must go through the same ones`);
  } else if (!/async function askTheRules\(/.test(route)) {
    fail("there is no one function that asks the rules");
  } else if (direct > 3) {
    fail(`the rules are called directly ${direct} times - they belong behind askTheRules`);
  } else if (!/intake_rules_ran_late/.test(route)) {
    fail("a scan filed late is not recorded, so the counselor is never thanked for it");
  } else {
    ok("a scan read later is decided by the same rules, recorded, and the counselor thanked then");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- INTAKE VERIFIED ---");
