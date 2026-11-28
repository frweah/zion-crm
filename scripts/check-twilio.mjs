/**
 * The Twilio half, asked rather than hoped at.
 *
 *   node --experimental-strip-types scripts/check-twilio.mjs
 *
 * Two kinds of question, and the first is the one that matters.
 *
 * **The signature.** A webhook that cannot prove a request is Twilio's is a
 * webhook anybody can post a client's STOP to, or a delivery status for
 * somebody else's message. It is also the one piece of this that cannot be
 * tested by using it: a wrong scheme either refuses every reply - which looks
 * like a quiet carrier - or accepts anything, which looks like nothing at all.
 * So it is run here against Twilio's own published example, with their token
 * and their expected hash, and then against requests built to fail: a
 * parameter changed, a parameter added, the same body at the other path.
 *
 * **The shape.** That the door knows nothing about either carrier, that only
 * one file does, that nothing sends from a bare number, and that the routes
 * prove themselves before they read anything. Asked of the code rather than
 * of a list of files, because a list is what goes stale - a third importer of
 * a provider next month is exactly the case this is for.
 */
import { createHmac } from "node:crypto";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { expectedSignature, signedUrl } from "../lib/twilio-signature.ts";
import { readSwitch } from "../lib/carrier-switch.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);
const root = new URL("../", import.meta.url);
const read = (p) => readFileSync(new URL(p, root), "utf8");

// ── the signature, against Twilio's own published example ────
//
// https://www.twilio.com/docs/usage/security - the worked example for an
// incoming call webhook. Their URL, their parameters, their auth token, their
// expected hash. Nothing here is this repository's own arithmetic, which is
// the point: if the scheme were wrong, agreeing with ourselves would prove it.
const THEIR_URL = "https://example.com/myapp.php?foo=1&bar=2";
const THEIR_PARAMS = {
  CallSid: "CA1234567890ABCDE",
  Caller: "+14158675310",
  Digits: "1234",
  From: "+14158675310",
  To: "+18005551212",
};
const THEIR_TOKEN = "12345";
const THEIR_SIGNATURE = "L/OH5YylLD5NRKLltdqwSvS0BnU=";

const mine = expectedSignature(THEIR_TOKEN, THEIR_URL, THEIR_PARAMS);
if (mine !== THEIR_SIGNATURE) {
  fail(
    `the signature does not match Twilio's published example - they say ${THEIR_SIGNATURE}, ` +
      `this says ${mine}, so every client's reply would be refused or anybody's would be taken`,
  );
} else {
  ok("the signature matches Twilio's own published example");
}

/** The faults. Each one is a request that must not produce that signature. */
const bent = [
  [
    "one digit of one parameter changed",
    () => expectedSignature(THEIR_TOKEN, THEIR_URL, { ...THEIR_PARAMS, Digits: "1235" }),
  ],
  [
    "a parameter added that Twilio did not send",
    () => expectedSignature(THEIR_TOKEN, THEIR_URL, { ...THEIR_PARAMS, Smuggled: "1" }),
  ],
  [
    "a parameter removed",
    () => {
      const fewer = { ...THEIR_PARAMS };
      delete fewer.Digits;
      return expectedSignature(THEIR_TOKEN, THEIR_URL, fewer);
    },
  ],
  [
    "the same body replayed at a different path",
    () =>
      expectedSignature(THEIR_TOKEN, "https://example.com/other.php?foo=1&bar=2", THEIR_PARAMS),
  ],
  [
    "the query string dropped",
    () => expectedSignature(THEIR_TOKEN, "https://example.com/myapp.php", THEIR_PARAMS),
  ],
  [
    "another account's auth token",
    () => expectedSignature("54321", THEIR_URL, THEIR_PARAMS),
  ],
];

for (const [say, compute] of bent) {
  if (compute() === THEIR_SIGNATURE) {
    fail(`${say} still produces Twilio's signature, so the check is not checking that`);
  }
}
if (problems.length === 0) ok(`${bent.length} bent requests all fail the signature`);

/**
 * And that the parameters are concatenated in the order Twilio means.
 *
 * "Sorted case-sensitively" is the part a well-meaning implementation gets
 * wrong: a locale-aware sort puts 'a' before 'B', and Twilio puts every
 * capital first. The expected string is built here, by hand, rather than
 * asked of the same function being tested.
 */
const mixed = { a: "1", B: "2", Ab: "3", ab: "4" };
// Capitals first, then by code unit: Ab, B, a, ab - so the string Twilio
// hashes is the URL followed by Ab3 B2 a1 ab4 with nothing between. A
// locale-aware sort would give a1 Ab3 ab4 B2, which is a different hash and a
// webhook that refuses every message with a mixed-case field in it.
const expectedOrder = createHmac("sha1", THEIR_TOKEN)
  .update(`${THEIR_URL}Ab3B2a1ab4`, "utf8")
  .digest("base64");
if (expectedSignature(THEIR_TOKEN, THEIR_URL, mixed) !== expectedOrder) {
  fail(
    "the parameters are not concatenated capitals-first, so a body with a mixed-case field " +
      "signs differently here than at Twilio and every such request is refused",
  );
} else {
  ok("parameters are concatenated in case-sensitive order, capitals first");
}

// ── the URL that gets signed ─────────────────────────────────

const bag = (headers) => ({ get: (name) => headers[name.toLowerCase()] ?? null });

const cases = [
  [
    "the forwarded host wins over the host the platform rewrote",
    "http://internal-lambda.local/api/twilio/sms",
    { "x-forwarded-host": "crm.zionvocrehab.com", "x-forwarded-proto": "https" },
    "https://crm.zionvocrehab.com/api/twilio/sms",
  ],
  [
    "https is assumed when nothing says otherwise",
    "http://crm.zionvocrehab.com/api/twilio/status",
    { host: "crm.zionvocrehab.com" },
    "https://crm.zionvocrehab.com/api/twilio/status",
  ],
  [
    "a query string is kept, because Twilio signs it",
    "http://internal/api/twilio/sms?x=1&y=2",
    { "x-forwarded-host": "crm.zionvocrehab.com" },
    "https://crm.zionvocrehab.com/api/twilio/sms?x=1&y=2",
  ],
  [
    "a list of forwarded protocols takes the first",
    "http://internal/api/twilio/sms",
    { "x-forwarded-host": "crm.zionvocrehab.com", "x-forwarded-proto": "https,http" },
    "https://crm.zionvocrehab.com/api/twilio/sms",
  ],
];

for (const [say, url, headers, want] of cases) {
  const got = signedUrl(url, bag(headers));
  if (got !== want) fail(`${say}: expected ${want}, got ${got}`);
}
ok(`${cases.length} rebuilt URLs are the one Twilio would have signed`);

// ── the shape ────────────────────────────────────────────────

const door = read("lib/sms.ts");
const provider = read("lib/text-provider.ts");
const twilio = read("lib/twilio.ts");
const inbound = read("app/api/twilio/sms/route.ts");
const status = read("app/api/twilio/status/route.ts");
const middleware = read("middleware.ts");

/**
 * The door knows nothing about either carrier.
 *
 * This is the whole of the two-layer rule, and it is one line to break: an
 * import of lib/twilio.ts here, "just for the status words", and there are two
 * places that decide who carries a message.
 */
if (/from "@\/lib\/(ghl|twilio)"/.test(door)) {
  fail("lib/sms.ts imports a provider directly, so the door now knows which carrier is live");
} else if (!/from "@\/lib\/text-provider"/.test(door)) {
  fail("lib/sms.ts does not go through lib/text-provider.ts, so there is no one place that switches");
} else {
  ok("the door records and asks permission, and knows no carrier");
}

/**
 * And only one file does know.
 *
 * Asked of every file rather than of a list: the exception is named here with
 * its reason, and a second exception has to be argued for rather than
 * appearing.
 *
 * lib/portal/deliver.ts is the one, and it is on its way out - the portal is
 * no longer planned, and docs/timing/telephony-cutover.md lists it for
 * removal once the portal is retired. It bypasses the door on purpose: that
 * path sends a sign-in code to somebody who has just typed their own number
 * in, and the door would refuse it for want of texting consent.
 */
/**
 * Every source file under lib/ and app/, so the rule below is asked of the
 * repository rather than of a list somebody has to remember to add to.
 */
const sources = [];
(function walk(dir) {
  for (const entry of readdirSync(new URL(dir, root))) {
    if (entry === "node_modules" || entry.startsWith(".")) continue;
    const rel = `${dir}/${entry}`;
    if (statSync(new URL(rel, root)).isDirectory()) walk(rel);
    else if (/\.(ts|tsx)$/.test(entry) && !entry.endsWith(".d.ts")) sources.push(rel);
  }
})("lib");
(function walk(dir) {
  for (const entry of readdirSync(new URL(dir, root))) {
    if (entry === "node_modules" || entry.startsWith(".")) continue;
    const rel = `${dir}/${entry}`;
    if (statSync(new URL(rel, root)).isDirectory()) walk(rel);
    else if (/\.(ts|tsx)$/.test(entry)) sources.push(rel);
  }
})("app");

const ALLOWED = new Set(["lib/text-provider.ts", "lib/portal/deliver.ts"]);

/**
 * What a file outside that set may still import from a carrier's module.
 *
 * The rule is that the *choice of carrier* is made in one place, not that the
 * word Twilio appears in one file. The two webhook routes are Twilio's own
 * endpoints and could not be anything else: they have to be able to prove a
 * request is Twilio's, and that is all they take. A route that imported
 * `sendSms` would be a second place deciding who carries a message, and this
 * is the difference the check has to be able to tell - the first version of
 * it could not, and failed the two routes for importing their own signature
 * reader.
 */
const RECEIVE_ONLY = new Set([
  // Proving a request is Twilio's. The two webhook routes are Twilio's own
  // endpoints and could not be anything else.
  "readSignedWebhook",
  "signingConfigured",
  "type Proof",
  "Proof",
  // Fetching the audio of a voicemail Twilio has already taken. It sends
  // nothing and chooses nothing: the call it belongs to arrived on a Twilio
  // webhook, so the carrier was decided before this is reached.
  "recordingAudio",
  // Building the URL Twilio should post back to. A string.
  "callbackUrl",
]);

/**
 * The list is closed, and that is the point.
 *
 * A name not on it fails, so `sendSms` imported into a route next month is
 * caught - which is the rule this is for. Adding a name here is a decision
 * somebody takes in a diff, with the reason beside it.
 */

const sendersOutside = [];
for (const path of sources) {
  if (ALLOWED.has(path) || path === "lib/ghl.ts" || path === "lib/twilio.ts") continue;
  const body = read(path);
  for (const m of body.matchAll(/import\s*{([^}]*)}\s*from\s*"@\/lib\/(ghl|twilio)"/g)) {
    const names = m[1]
      .split(",")
      .map((n) => n.trim().split(/\s+as\s+/)[0].trim())
      .filter(Boolean);
    const sending = names.filter((n) => !RECEIVE_ONLY.has(n));
    if (sending.length > 0) sendersOutside.push(`${path} (${sending.join(", ")})`);
  }
}

if (sendersOutside.length > 0) {
  fail(
    `${sendersOutside.join("; ")} reach a carrier to send, so which one is live is decided in ` +
      "more than one place and a cutover would miss one",
  );
} else {
  ok(
    `of ${sources.length} files, only lib/text-provider.ts and the portal's own path send through a carrier`,
  );
}

/**
 * Nothing sends from a bare number.
 *
 * The messaging service carries the registered campaign, the sender pool and
 * Advanced Opt-Out. A message sent with `From` instead would go out around all
 * three, which on A2P traffic is how a number gets filtered rather than
 * delivered - and it would be one word's difference in this file.
 */
if (!/MessagingServiceSid:/.test(twilio)) {
  fail("lib/twilio.ts does not send through the messaging service");
} else if (/\bFrom:\s/.test(twilio)) {
  fail(
    "lib/twilio.ts sets From on a message, which sends around the messaging service and so " +
      "around the campaign registration and the opt-out list",
  );
} else {
  ok("every text goes through the messaging service, never from a bare number");
}

if (!/StatusCallback/.test(twilio) || !/statusCallback/.test(provider)) {
  fail(
    "a text is sent without asking for a delivery status, so 'accepted' would read as " +
      "'delivered' again - which is the fault 0287 exists for",
  );
} else {
  ok("every text asks for its delivery status to come back");
}

// ── the routes ───────────────────────────────────────────────

for (const [name, body] of [
  ["app/api/twilio/sms/route.ts", inbound],
  ["app/api/twilio/status/route.ts", status],
]) {
  /**
   * The call, not the word.
   *
   * The first version of this took the index of "readSignedWebhook", which is
   * in the import on line three - so a route that read the body at the top of
   * the handler and proved it afterwards passed, which is the one shape this
   * is here to refuse. It asks for the call now, and the fault suite watches
   * it fail with the fault put back.
   */
  const proves = body.search(/readSignedWebhook\(request\)/);
  const reads = body.search(/request\.formData|request\.json|request\.text/);
  if (proves < 0) {
    fail(`${name} does not prove the request is Twilio's`);
  } else if (reads >= 0 && reads < proves) {
    fail(`${name} reads the body before it has proved who sent it`);
  }
  if (/x-zion-secret|searchParams\.get\("key"\)/.test(body)) {
    fail(`${name} falls back to a shared secret, which is weaker than the signature it already has`);
  }
}
ok("both routes prove the request before reading it, and have no second way in");

/**
 * The inbound route decides nothing.
 *
 * Every keyword, the rating, the consent withdrawal and the contact-log line
 * are the database's (0388). A second provider must not become a second set of
 * rules, and the way that happens is a route "helpfully" checking for STOP.
 */
if (/\bSTOP\b|\bUNSUBSCRIBE\b|\bSTART\b|consent/i.test(inbound.replace(/\/\*[\s\S]*?\*\//g, ""))) {
  fail(
    "app/api/twilio/sms/route.ts decides something about keywords or consent itself, rather " +
      "than handing the message to record_incoming_sms",
  );
} else if (!/rpc\("record_incoming_sms"/.test(inbound)) {
  fail("app/api/twilio/sms/route.ts does not hand the message to record_incoming_sms");
} else {
  ok("the inbound route records the message and decides nothing about it");
}

if (!/<Response><\/Response>/.test(inbound)) {
  fail("the inbound route does not answer with empty TwiML, so Twilio may reply to the client for us");
} else {
  ok("an inbound message is answered with empty TwiML and nobody is replied to automatically");
}

if (!/rpc\("record_text_status"/.test(status) || /record_incoming_sms/.test(status)) {
  fail("the status route does not do its own job, or does the inbound route's");
}

if (!/"\/api\/twilio"/.test(middleware)) {
  fail(
    "middleware.ts does not wave /api/twilio through, so Twilio's POSTs are redirected to the " +
      "login page - a 307 the caller reads as success, which is how a STOP disappears",
  );
} else {
  ok("/api/twilio is past the session gate, like the other machine endpoints");
}

// ── the switch ───────────────────────────────────────────────

if (!/rpc\("sms_provider"\)/.test(provider)) {
  fail("lib/text-provider.ts does not ask the database which carrier is live");
}
/**
 * And a switch that cannot be read refuses the send.
 *
 * Run, not grepped for. The first version of this looked for the sentence in
 * the file, and a fault that added a fallback *above* the refusal passed it -
 * the words were still there, in a branch nothing could reach. The rule lives
 * in lib/carrier-switch.ts with no imports and no environment so that it can
 * be asked instead.
 *
 * The practice has been caught twice by code reading a failure as an answer:
 * middleware reading an auth error as "revoked", and getCurrentStaff reading a
 * failed query as "no access" and signing the whole practice out. Here it
 * would be worse than either - a default would text a client from whichever
 * number the practice is not using, and their reply would arrive where nobody
 * is looking.
 */
const answers = [
  ["ghl", { data: "ghl", error: null }, "ghl"],
  ["twilio", { data: "twilio", error: null }, "twilio"],
  ["an error from the database", { data: null, error: { message: "connection lost" } }, null],
  ["no row at all", { data: null, error: null }, null],
  ["a carrier nothing here can send through", { data: "telnyx", error: null }, null],
  ["something that is not a word", { data: 7, error: null }, null],
  ["an answer and an error together", { data: "twilio", error: { message: "stale" } }, null],
];

for (const [say, answer, want] of answers) {
  const got = readSwitch(answer);
  if (want === null) {
    if (got.ok) {
      fail(
        `the switch answered ${say} and the practice sent the text anyway, through ` +
          `${got.carrier} - which is whichever number it happens not to be using`,
      );
    } else if (!/nothing was sent/.test(got.error)) {
      fail(`the switch answered ${say} and the refusal does not say nothing was sent: ${got.error}`);
    }
  } else if (!got.ok || got.carrier !== want) {
    fail(`the switch answered ${say} and this read it as ${got.ok ? got.carrier : got.error}`);
  }
}
ok(`${answers.length} answers from the switch, and every way of not knowing stops the send`);

if (!/readSwitch\(/.test(provider)) {
  fail("lib/text-provider.ts does not read the switch through the rule, so the rule is not the one that runs");
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the Twilio half`);
  process.exit(1);
}
console.log("\n  ok  the signature is Twilio's, the door knows no carrier, and one file switches");
