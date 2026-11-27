/**
 * Calls in the browser, asked of the code.
 *
 *   node --experimental-strip-types scripts/check-voice.mjs
 *
 * The database half of part B is `verify_a_call_is_on_the_record`, and it is
 * where the rules about what a call *is* are held. This is the half no SQL can
 * see: that every route under a prefix the middleware waves through proves who
 * is asking, that the greeting is the owner's words, that a token is one
 * person's for an hour, and that the telephone does not cost a page anything
 * until somebody is allowed to use it.
 *
 * The first of those is the one worth having. `/api/twilio` is in
 * PUBLIC_PATHS as a prefix, and the middleware's own comment says why that is
 * normally refused: "Listed one by one, never /api as a whole: a future API
 * route that forgets to authorize should be caught by this gate rather than
 * quietly exposed by it." A prefix is exactly the shape that can forget, so
 * the gate moves here: each route under it either checks a Twilio signature
 * or requires a session, and this says which.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { GREETING, RING_SECONDS, VOICEMAIL_SECONDS, PRESENCE_REFRESH_MS, dialable, voiceToken, inboundTwiml, outboundTwiml } from "../lib/twilio-voice.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);
const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");

// ── every route under the prefix proves who is asking ────────

const dir = "app/api/twilio";
const routes = [];
(function walk(where) {
  for (const entry of readdirSync(new URL(where, root))) {
    const rel = `${where}/${entry}`;
    if (statSync(new URL(rel, root)).isDirectory()) walk(rel);
    else if (entry === "route.ts") routes.push(rel);
  }
})(dir);

if (routes.length < 2) {
  fail(`only ${routes.length} route(s) found under ${dir}, so this is asking almost nothing`);
}

const unguarded = [];
for (const route of routes) {
  const body = read(route);
  const signed = /readSignedWebhook\(request\)/.test(body);
  const sessioned = /await (getCurrentStaff|requireStaff)\(\)/.test(body);
  if (!signed && !sessioned) unguarded.push(route);

  // And a signed route must prove it before it reads the body.
  if (signed) {
    const proves = body.search(/readSignedWebhook\(request\)/);
    const reads = body.search(/request\.formData|request\.json|request\.text/);
    if (reads >= 0 && reads < proves) {
      fail(`${route} reads the body before it has proved who sent it`);
    }
  }
}

if (unguarded.length > 0) {
  fail(
    `${unguarded.join(", ")} sit under a prefix the middleware waves through and prove nothing - ` +
      "no Twilio signature and no session, so anybody on the internet can call them",
  );
} else {
  ok(`all ${routes.length} routes under /api/twilio prove a signature or a session`);
}

/**
 * The one with a session rather than a signature is the token.
 *
 * Said out loud, so that a second one appearing is a decision somebody took
 * rather than a thing that happened: every other route here is Twilio's own
 * and arrives with no session at all.
 */
const sessioned = routes.filter((r) => /await (getCurrentStaff|requireStaff)\(\)/.test(read(r)));
if (sessioned.length !== 1 || !sessioned[0].includes("voice-token")) {
  fail(
    `the routes with a session are ${sessioned.join(", ") || "none"}, and the only one that should ` +
      "have one is voice-token - everything else under this prefix is Twilio calling us",
  );
} else {
  ok("the token is the one route with a session; the rest are Twilio's");
}

// ── the greeting is the owner's words ────────────────────────

const WORDS =
  "You've reached Zion Voc Rehab. We can't take your call right now. " +
  "Leave your name, number and a short message and we'll call you back, " +
  "or text this number for a quicker reply.";

if (GREETING !== WORDS) {
  fail(
    "the greeting is not the owner's words any more. It is the one sentence in this system a " +
      `member of the public hears, and it now reads:\n      "${GREETING}"`,
  );
} else {
  ok("the greeting is word for word what the owner wrote");
}

// It has to actually reach the caller, in the TwiML.
const empty = inboundTwiml({
  callerId: "+13855550123",
  ring: [],
  callerLabel: "ZZ Nobody",
  clientId: null,
  recordingStatusCallback: "https://example.test/api/twilio/recording-status",
});
if (!empty.includes(WORDS.replace(/'/g, "&apos;"))) {
  fail("the greeting is not in the TwiML a caller gets when nobody is at a desk");
}
if (/<Dial/.test(empty)) {
  fail(
    "nobody is on the phones and the caller is still made to listen to twenty-five seconds of " +
      "ringing before the greeting",
  );
}
if (!empty.includes(`maxLength="${VOICEMAIL_SECONDS}"`)) {
  fail("the recorder has no limit on it, so one caller can leave an hour");
}
if (!/recordingStatusCallback=/.test(empty)) {
  fail("a message is recorded and nothing is told about it, so nobody ever hears it");
}
if (/transcribe=/.test(empty)) {
  fail(
    "the TwiML asks Twilio to transcribe the message, and the owner's instruction is that it goes " +
      "through the practice's own Azure path",
  );
}

const ringing = inboundTwiml({
  callerId: "+13855550123",
  ring: ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"],
  callerLabel: "ZZ Somebody & Son",
  clientId: "33333333-3333-3333-3333-333333333333",
  recordingStatusCallback: null,
});
if ((ringing.match(/<Client>/g) ?? []).length !== 2) {
  fail("two desks are at their desks and the TwiML does not ring both");
}
if (!ringing.includes(`timeout="${RING_SECONDS}"`)) {
  fail("the ring has no timeout, so a caller waits as long as Twilio feels like");
}
if (!ringing.includes("ZZ Somebody &amp; Son")) {
  fail(
    "a caller whose name has an ampersand in it produces TwiML Twilio refuses, which is an error " +
      "tone for somebody called Fisher & Son",
  );
}
if (!ringing.includes('name="caller"') || !ringing.includes('name="clientId"')) {
  fail("the browser is rung without being told who is calling, so the banner says a phone number");
}
ok("a caller hears the greeting when nobody is there, and every desk is rung when somebody is");

// ── a number this practice will dial ────────────────────────

const dialling = [
  ["+13855550123", "+13855550123"],
  ["385-555-0123", "+13855550123"],
  ["(385) 555-0123", "+13855550123"],
  ["13855550123", "+13855550123"],
  ["+447700900123", null],
  ["+2348012345678", null],
  ["900", null],
  ["", null],
];
for (const [raw, want] of dialling) {
  const got = dialable(raw);
  if (got !== want) {
    fail(`dialable(${JSON.stringify(raw)}) is ${JSON.stringify(got)}, expected ${JSON.stringify(want)}`);
  }
}
ok(`${dialling.length} numbers are judged, and nothing outside the US and Canada is dialled`);

// ── the token is one person's, for an hour ──────────────────

const { token, expiresAt } = voiceToken({
  accountSid: "ACzz",
  apiKeySid: "SKzz",
  apiKeySecret: "zz-secret",
  identity: "44444444-4444-4444-4444-444444444444",
  applicationSid: "APzz",
});
const [header, payload] = token
  .split(".")
  .slice(0, 2)
  .map((part) => JSON.parse(Buffer.from(part.replace(/-/g, "+").replace(/_/g, "/"), "base64").toString()));

if (header.cty !== "twilio-fpa;v=1") {
  fail(`the token's content type is ${JSON.stringify(header.cty)}, which Twilio's SDK will not take`);
}
if (payload.iss !== "SKzz" || payload.sub !== "ACzz") {
  fail("the token is issued by the wrong thing: Twilio wants the API key as issuer and the account as subject");
}
if (payload.grants?.identity !== "44444444-4444-4444-4444-444444444444") {
  fail("the token does not carry the staff id, so a call answered on it names nobody");
}
if (payload.grants?.voice?.incoming?.allow !== true) {
  fail("the token does not allow incoming calls, so the client line rings nothing");
}
if (payload.exp - payload.iat > 3600) {
  fail(
    `the token lasts ${payload.exp - payload.iat} seconds. An hour at most: a token that outlives ` +
      "the session it was issued for is somebody else answering the client line",
  );
}
if (expiresAt < Date.now()) {
  fail("the token is already expired when it is issued");
}
const withoutApp = voiceToken({
  accountSid: "ACzz",
  apiKeySid: "SKzz",
  apiKeySecret: "zz-secret",
  identity: "zz",
  applicationSid: null,
});
const noAppPayload = JSON.parse(
  Buffer.from(withoutApp.token.split(".")[1].replace(/-/g, "+").replace(/_/g, "/"), "base64").toString(),
);
if (noAppPayload.grants?.voice?.outgoing) {
  fail("a deployment with no TwiML app is handed an outgoing grant pointing at nothing");
}
if (noAppPayload.grants?.voice?.incoming?.allow !== true) {
  fail("a deployment with no TwiML app cannot even take calls, which is the half that matters");
}
ok("a token is one staff member's, allows incoming, and lasts an hour at most");

// ── the outbound caller id is a number we own ───────────────

const out = outboundTwiml({ to: "+13855550123", callerId: "+13854063432" });
if (!out.includes('callerId="+13854063432"')) {
  fail("an outbound call does not show the practice's number, so nobody answers it");
}

const voiceOut = read("app/api/twilio/voice-out/route.ts");
if (!/TWILIO_FROM_NUMBER/.test(voiceOut)) {
  fail(
    "the outbound caller id is not the number the Twilio account holds, and Twilio refuses a " +
      "caller id it does not own - which during the move is the test number, not the practice line",
  );
}
if (!/dialable\(/.test(voiceOut)) {
  fail("the outbound route dials whatever it is given, which is the one place this could call Nigeria");
}
// The call, not the word: `/staff_on_the_phones/` also matches
// `staff_on_the_phones_x`, so a fault that renamed the call to a function
// that does not exist passed the first time this was run.
if (!/rpc\("staff_on_the_phones"\)/.test(voiceOut)) {
  fail("a token that has outlived its session can still place calls on the practice's account");
}
ok("an outbound call shows a number the account owns, and only a signed-in desk places one");

// ── the telephone costs a page nothing until it is used ────

const panel = read("app/(app)/softphone.tsx");
if (!/await import\("@twilio\/voice-sdk"\)/.test(panel)) {
  fail(
    "the voice SDK is imported at the top of a component mounted in the shell, so every page in " +
      "the practice carries a hundred kilobytes of telephone whether the seat answers calls or not",
  );
}
const askedFirst = panel.search(/fetch\("\/api\/twilio\/voice-token"/);
const imported = panel.search(/await import\("@twilio\/voice-sdk"\)/);
if (askedFirst < 0 || imported < 0 || imported < askedFirst) {
  fail("the SDK is loaded before anybody has said this seat may take calls");
}
if (/getUserMedia/.test(panel)) {
  fail(
    "the panel asks for the microphone itself. It must not: a permission prompt on page load is " +
      "how somebody clicks Block once and then cannot answer the telephone for a week",
  );
}
if (!/Calls off — allow the microphone/.test(panel)) {
  fail("a refused microphone says nothing, so the telephone looks broken rather than switched off");
}
if (!new RegExp(String(PRESENCE_REFRESH_MS)).test(panel) && !/refreshMs/.test(panel)) {
  fail("the panel never says it is still there, so the desk drops off the phones after ninety seconds");
}
const layout = read("app/(app)/layout.tsx");
if (!/<Softphone \/>/.test(layout)) {
  fail(
    "the telephone is not in the shell, so a call arriving only reaches somebody who happens to " +
      "be on the right screen",
  );
}
ok("the telephone loads nothing until a seat is allowed it, and asks for the microphone only to answer");

// ── and the words a person reads ────────────────────────────

const dialButton = read("app/(app)/dial.tsx");
if (/window\.Twilio|voice-sdk/.test(dialButton)) {
  fail("a phone number on a screen carries its own telephone, so a client record loads a dozen");
}
if (!/zion:dial/.test(dialButton) || !/zion:dial/.test(panel)) {
  fail("pressing a number does not reach the one telephone in the shell");
}
ok("a number on a screen asks the shell's telephone to dial rather than holding one");

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with calls in the browser`);
  process.exit(1);
}
console.log("\n  ok  every route proves who is asking, the greeting is the owner's, and the token is one person's");
