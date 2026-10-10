/**
 * Mail, checked (Messaging brief, M).
 *
 *   node scripts/check-mail.mjs        (also runs before every `npm run build`)
 *
 * What the brief asks to be verifiable, held in the code:
 *
 *   A message body is never stored. The two files that talk to Graph's mail
 *   (lib/mail.ts, lib/mail-send.ts) may not touch the database, and no file
 *   that uses them may write to it - no insert, update, upsert, delete or rpc.
 *   (supabase/verify_mail.sql holds the other half: no table has anywhere to
 *   put one.)
 *
 *   Mail.Send is exercised only by Send, Reply and Forward, and Mail.ReadWrite
 *   only by Delete (a move to Deleted Items). Graph's send, reply, forward and
 *   move are called in lib/mail-send.ts and nowhere else, and lib/mail-send.ts
 *   is used by app/(app)/mail/actions.ts and nothing else, from exported
 *   functions named send*, reply*, forward* or delete* - the buttons.
 *
 *   A shared mailbox is opened only through resolveMailbox. Every file that
 *   reads mail imports it and calls it before any read.
 */
import { readFileSync, readdirSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const walk = (dir) =>
  readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    if (name === "node_modules" || name.startsWith(".")) return [];
    return statSync(full).isDirectory() ? walk(full) : [full];
  });
const rel = (f) => path.relative(root, f).split(path.sep).join("/");
const files = ["app", "lib"].flatMap((d) => walk(path.join(root, d))).filter((f) => /\.(ts|tsx)$/.test(f));
const src = new Map(files.map((f) => [rel(f), readFileSync(f, "utf8")]));

const READ = "lib/mail.ts";
const SEND = "lib/mail-send.ts";
const ACTIONS = "app/(app)/mail/actions.ts";
// The one place that sends mail without somebody pressing Send: the intake's
// reply to the counselor (Intake Automation Brief, Rule 4). It is allowed
// here and then held to much less than ACTIONS is - one fixed sentence, as a
// reply and nothing else - because "mail is only sent by a person" stopped
// being the whole truth and a rule that is nearly true is worse than one that
// says exactly what it means.
const INTAKE = "lib/intake-mail.ts";
const DB_WRITE = /\.(insert|update|upsert|delete)\(|\.rpc\(/;

// ── bodies are never stored ──────────────────────────────────
for (const f of [READ, SEND]) {
  if (!src.has(f)) fail(`${f} is missing`);
  else if (/supabase/i.test(src.get(f).replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1"))) fail(`${f} reaches for the database`);
}
const usesMail = [...src.entries()].filter(([f, s]) => f !== READ && /from "@\/lib\/mail"/.test(s));
const usesSend = [...src.entries()].filter(([f, s]) => f !== SEND && /from "@\/lib\/mail-send"/.test(s));
for (const [f, s] of [...usesMail, ...usesSend]) {
  if (DB_WRITE.test(s)) fail(`${f} reads or sends mail and also writes to the database`);
}
if (!problems.length) ok(`mail is read and sent without touching the database (${usesMail.length + usesSend.length} files use it)`);

// ── Mail.Send only from Send, Reply and Forward ─────────────
const sendPaths = /\/sendMail|\/replyAll|\/reply["`/]|\/forward["`/]|\/send["`]|\/move["`]/;
for (const [f, s] of src) {
  if (f !== SEND && sendPaths.test(s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1"))) {
    fail(`${f} calls a Graph send path; only ${SEND} may`);
  }
}
for (const [f] of usesSend) {
  if (f !== ACTIONS && f !== INTAKE) fail(`${f} uses ${SEND}; only ${ACTIONS} and ${INTAKE} may`);
}

// ── and the automated one composes nothing ──────────────────
//
// Two things leave here without a person pressing Send: the reply to a
// document (Rule 4) and the nudge about a referral with no authorization
// (Rule 6). The rule is not "one message" any more, so it is the thing that
// actually matters instead - this file composes no prose. THANKS is a
// constant; the nudge's words are built in the database beside the rule that
// decides a nudge is owed, and are handed in. Anything else sent from here
// would be the practice saying something nobody can find the source of.
if (src.has(INTAKE)) {
  const i = src.get(INTAKE);
  const bare = i.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1");
  const replies = (bare.match(/replyOwn\(/g) ?? []).length;
  const withThanks = (bare.match(/replyOwn\([^)]*\bTHANKS\b[^)]*\)/g) ?? []).length;
  // What reaches a send call, rather than every string in the file - the first
  // version of this flagged the module's own "a nudge with no words in it",
  // which is an error message and never leaves the building. What matters is
  // that the subject and the body passed to sendNew are identifiers: handed
  // in, not written here.
  //
  // The first version matched on `));` where the call ends `});`, so it found
  // no send calls at all and passed without checking anything - which a
  // deliberately composed message then sailed through. Hence the second half:
  // finding none is a failure, not a pass.
  const sends = bare.match(/sendNew\([\s\S]{0,300}?\}\);/g) ?? [];
  const prose = sends.filter((call) => !/subject,\s*text:\s*body\s*\}/.test(call));
  if (!/export const THANKS = "Received, thank you\.";/.test(i)) {
    fail(`${INTAKE} does not hold the one sentence the brief specifies`);
  } else if (replies === 0 || replies !== withThanks) {
    fail(`${INTAKE} has ${replies} reply call(s) and ${withThanks} that send THANKS - they must be the same`);
  } else if (/(forwardOwn|moveToDeletedItems)/.test(bare)) {
    fail(`${INTAKE} forwards or deletes mail; it may only reply and send the nudge`);
  } else if (sends.length === 0) {
    fail(`${INTAKE} has no send call this check can read, so it is checking nothing`);
  } else if (prose.length) {
    fail(`${INTAKE} composes what it sends - the subject and body must be handed in, not written here`);
  } else if (/supabase|createAdminClient/i.test(bare)) {
    fail(`${INTAKE} reaches for the database; it holds a mail token and must not`);
  } else {
    ok(`${INTAKE} is the one automated sender, and composes nothing it sends`);
  }
}

// ── shared mailboxes through one door ───────────────────────
const readers = usesMail.filter(([, s]) => /\b(listMessages|getMessage|listAttachments|fetchAttachment)\(/.test(s));
for (const [f, s] of readers) {
  if (f === INTAKE) {
    // resolveMailbox answers "may this person open that mailbox", and the
    // intake has no person - it runs behind a cron secret with nobody signed
    // in. So it is held to the stricter thing instead: it is handed its
    // mailbox and cannot choose one, and the only name its caller may pass is
    // the fixed INTAKE_MAILBOX (scripts/check-intake.mjs holds that end).
    if (/searchParams|request\.|requested/.test(s)) {
      fail(`${INTAKE} takes a mailbox from the request; it may only read the one it is handed`);
    } else if (!/mailbox: string \| null/.test(s)) {
      fail(`${INTAKE} does not take its mailbox as an argument, so nothing decides it`);
    }
  } else if (!/resolveMailbox\(/.test(s)) {
    fail(`${f} reads mail without resolveMailbox deciding whose mailbox`);
  }
}
if (!problems.some((p) => p.includes("resolveMailbox"))) ok(`every mail read goes through resolveMailbox (${readers.length} files)`);

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- MAIL VERIFIED ---");
