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
 *   Mail.Send is exercised only by Send, Reply and Forward. Graph's send,
 *   reply and forward are called in lib/mail-send.ts and nowhere else, and
 *   lib/mail-send.ts is used by app/(app)/mail/actions.ts and nothing else,
 *   from exported functions named send*, reply* or forward* - the three
 *   buttons.
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
const sendPaths = /\/sendMail|\/replyAll|\/reply["`/]|\/forward["`/]|\/send["`]/;
for (const [f, s] of src) {
  if (f !== SEND && sendPaths.test(s.replace(/\/\*[\s\S]*?\*\//g, "").replace(/(^|[^:])\/\/.*$/gm, "$1"))) {
    fail(`${f} calls a Graph send path; only ${SEND} may`);
  }
}
for (const [f] of usesSend) {
  if (f !== ACTIONS) fail(`${f} uses ${SEND}; only ${ACTIONS} may`);
}
if (src.has(ACTIONS)) {
  const a = src.get(ACTIONS);
  const exported = [...a.matchAll(/export async function (\w+)/g)].map((m) => m[1]);
  const stray = exported.filter((n) => !/^(send|reply|forward)[A-Z]/.test(n));
  if (stray.length) fail(`${ACTIONS} exports ${stray.join(", ")} - only send*, reply* and forward* belong there`);
}
if (!problems.some((p) => /send path|uses lib\/mail-send|exports/.test(p))) ok("Mail.Send is used only by the Send, Reply and Forward actions");

// ── shared mailboxes through one door ───────────────────────
const readers = usesMail.filter(([, s]) => /\b(listMessages|getMessage|listAttachments|fetchAttachment)\(/.test(s));
for (const [f, s] of readers) {
  if (!/resolveMailbox\(/.test(s)) fail(`${f} reads mail without resolveMailbox deciding whose mailbox`);
}
if (!problems.some((p) => p.includes("resolveMailbox"))) ok(`every mail read goes through resolveMailbox (${readers.length} files)`);

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- MAIL VERIFIED ---");
