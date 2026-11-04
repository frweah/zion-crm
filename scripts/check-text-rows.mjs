/**
 * A list of texts says which way each one went, and who said it (1a).
 *
 *   node scripts/check-text-rows.mjs
 *
 * The complaint behind 1a was not that the screens were wrong. It was that a
 * line of words with nothing beside it reads whichever way the reader expects:
 * "can you send that again" is the client asking or the practice offering, and
 * on a screen listing four clients "from them" names nobody.
 *
 * Two screens show texts and they read different tables - the client's record
 * reads `sms_messages`, the inbox reads the mirror in `messages` - so the rule
 * has to hold of both or one text gets described two ways. `lib/text-rows.ts`
 * is the one place that decides, which is why it has no imports: the rules are
 * run here over made-up rows rather than read.
 *
 * The second half asks which screens show a text at all, and insists each one
 * goes through that file. Asked of the screens rather than of a list of them,
 * because the list is what goes stale: a third screen showing texts next month
 * is exactly the case this is for.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { senderOf, lastLine, statusOf, canRetry, TEXT_LAPSE_MINUTES } from "../lib/text-rows.ts";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

// ── what the rules say over made-up rows ─────────────────────

const incoming = { direction: "Incoming", status: "Received", created_at: "2026-11-03T15:00:00Z" };
const bySomebody = {
  direction: "Outgoing",
  status: "Sent",
  created_at: "2026-11-03T15:00:00Z",
  created_by: "staff-1",
  kind: "Manual",
};
const byTheSystem = {
  direction: "Outgoing",
  status: "Sent",
  created_at: "2026-11-03T15:00:00Z",
  created_by: null,
  kind: "Reminder",
};
const senders = { "staff-1": "Margaret Paasa" };

if (senderOf(incoming, "Alex Winter", senders) !== "Alex Winter") {
  fail("a text from the client is not named as the client's");
} else if (senderOf(bySomebody, "Alex Winter", senders) !== "Margaret Paasa") {
  fail("a text somebody sent does not say who sent it");
} else if (senderOf(byTheSystem, "Alex Winter", senders) !== "the practice") {
  fail("a reminder nobody typed is attributed to a person");
} else if (senderOf(incoming, "   ", senders) !== "the client") {
  fail("a text from a client with no name on file says nothing at all");
} else {
  ok("a text names the client who sent it, the person who sent it, or the practice");
}

// A picture with no words is not an empty line, and the direction is the
// mirror's sender_kind rather than a column of its own.
const picture = {
  sender_kind: "client",
  sender: "",
  body: "   ",
  media_url: "https://example.test/zq.jpg",
};
const answered = { sender_kind: "staff", sender: "Margaret Paasa", body: "On its way", media_url: null };
const nightly = { sender_kind: "system", sender: "Reminder", body: "Appointment tomorrow", media_url: null };

const p = lastLine(picture, "Alex Winter");
const a = lastLine(answered, "Alex Winter");
const n = lastLine(nightly, "Alex Winter");

if (p.direction !== "In" || p.who !== "Alex Winter") {
  fail("a picture from the client does not read as coming in from them");
} else if (p.words !== "a picture") {
  fail("a picture with no words in it shows as an empty line");
} else if (a.direction !== "Out" || a.who !== "Margaret Paasa") {
  fail("an answer does not read as going out from whoever wrote it");
} else if (n.direction !== "Out" || n.who !== "Reminder") {
  fail("a nightly reminder does not read as going out");
} else if (lastLine({ sender_kind: "staff", sender: null, body: "x", media_url: null }, "A").who !== "the practice") {
  fail("a text with no sender recorded is attributed to nobody");
} else {
  ok("the last line of a thread says which way it went, who said it, and names a picture");
}

// ── five minutes, and not before ─────────────────────────────

const now = new Date("2026-11-03T15:00:00Z");
const minutesAgo = (m) => ({
  direction: "Outgoing",
  status: "Queued",
  created_at: new Date(now.getTime() - m * 60000).toISOString(),
});

if (statusOf(minutesAgo(1), now) !== "Queued") {
  fail("a text written a minute ago is already being given up on");
} else if (statusOf(minutesAgo(TEXT_LAPSE_MINUTES), now) !== "Not delivered") {
  fail(`a text silent for ${TEXT_LAPSE_MINUTES} minutes still reads as going`);
} else if (statusOf({ ...minutesAgo(90), status: "Scheduled" }, now) !== "Scheduled") {
  fail("a text waiting for its window reads as not delivered");
} else if (statusOf({ ...minutesAgo(90), direction: "Incoming", status: "Received" }, now) !== "Received") {
  fail("a text that came in is judged against the five minutes");
} else if (statusOf({ ...minutesAgo(90), status: "Delivered" }, now) !== "Delivered") {
  fail("a text the provider delivered is read as not delivered");
} else {
  ok("a screen reaches 'Not delivered' at five minutes, and leaves a waiting one alone");
}

if (canRetry({ ...minutesAgo(90), provider_message_id: "ghl-1" }, now)) {
  fail("a text the provider accepted is offered a retry, which would text them twice");
} else if (!canRetry({ ...minutesAgo(90), provider_message_id: null }, now)) {
  fail("a text nobody heard about is not offered a retry");
} else if (canRetry({ ...minutesAgo(1), provider_message_id: null }, now)) {
  fail("a text still going is offered a retry");
} else if (canRetry({ ...minutesAgo(90), status: "Delivered", provider_message_id: null }, now)) {
  fail("a text the provider delivered is offered a retry, which would text them twice");
} else {
  ok("retry is offered on a text nobody heard about, and on nothing else");
}

// ── and every screen showing a text goes through it ──────────

function screens(dir, found = []) {
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      if (name !== "node_modules" && name !== ".next") screens(path, found);
    } else if (name.endsWith(".tsx") || name.endsWith(".ts")) {
      found.push(path);
    }
  }
  return found;
}

// What makes a file a list of texts: it names a text's own columns. Either the
// row's direction beside its words, or the inbox's last_body. A file that
// merely mentions texting is not one.
const SHOWS_A_TEXT = (src) =>
  (/\bdirection\b/.test(src) && /\bsms_messages\b|\bTextRow\b/.test(src)) || /\blast_body\b/.test(src);

const DECIDES = /\bsenderOf\(|\blastLine\(/;

// Two files name a text's columns without listing any: the action that sends
// one, and the library that sends it. Named rather than pattern-matched so a
// third is a decision somebody takes rather than a regex that quietly widens.
const NOT_A_LIST = new Set([
  join("app", "(app)", "clients", "[id]", "text-actions.ts"),
  join("app", "(app)", "clients", "[id]", "page.tsx"),
  join("app", "(app)", "messages", "texts", "actions.ts"),
]);

const listing = [];
for (const path of screens("app")) {
  const rel = path.replace(/^app[\\/]/, "app/").replace(/\//g, "\\").replace(/^app\\/, "app\\");
  const src = readFileSync(path, "utf8");
  if (!SHOWS_A_TEXT(src)) continue;
  const key = path.replace(/\//g, "\\");
  if (NOT_A_LIST.has(key)) continue;
  listing.push(key);
  if (!DECIDES.test(src)) {
    fail(`${rel} lists texts without saying which way each one went or who said it`);
  }
}

if (listing.length === 0) {
  fail("no screen was found listing texts, so this check proves nothing");
} else if (problems.length === 0) {
  ok(`all ${listing.length} screens listing texts say which way each went and who said it`);
}

if (problems.length) {
  console.error("\nFAILED");
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
console.log("\n--- TEXT ROWS VERIFIED ---");
