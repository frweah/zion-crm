/**
 * Team chat, checked where no database is needed (0272-0275).
 *
 *   node scripts/check-team-chat.mjs
 *
 * The brief asks for a prebuild check that Realtime is on and row-level
 * security is on. Prebuild runs on Vercel with no database credentials, so it
 * cannot ask the database anything — the live question is asserted in
 * verify_team_chat.sql, which has a connection. What this asks instead is the
 * migrations: whether the practice ever said to turn them on, and whether
 * anything later said to turn them off. That is the half that can rot in a
 * pull request, which is the half prebuild is for.
 *
 * And one thing only a static check can do well: **four places read messages
 * and all four have to agree.** The read policy, `search_messages`, `my_unread`
 * and `client_chat_mentions` each decide for themselves whether a hidden
 * message is visible, because three of them run as their owner and the policy
 * does not reach inside them. Three agreeing and one not is a message somebody
 * took down coming back in a search.
 */
import { readFile, readdir } from "node:fs/promises";

const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

const DIR = new URL("../supabase/migrations/", import.meta.url);
const names = (await readdir(DIR)).filter((n) => n.endsWith(".sql")).sort();
const files = [];
for (const name of names) {
  files.push({ name, text: await readFile(new URL(name, DIR), "utf8") });
}
/** Every migration that mentions the thing, oldest first. */
const mentioning = (re) => files.filter((f) => re.test(f.text));
/** The newest one, which is the one the database is running. */
const newest = (re) => mentioning(re).at(-1) ?? null;

// ── realtime, said once and never unsaid ─────────────────────
const LIVE = ["conversations", "messages", "read_receipts"];
for (const table of LIVE) {
  const added = mentioning(
    new RegExp(`alter publication supabase_realtime add table public\\.${table}\\b`),
  );
  const dropped = mentioning(
    new RegExp(`alter publication supabase_realtime drop table public\\.${table}\\b`),
  );
  if (added.length === 0) {
    fail(`nothing publishes ${table} for realtime, so a message would not arrive until a reload`);
  } else if (dropped.length > 0 && dropped.at(-1).name > added.at(-1).name) {
    fail(`${dropped.at(-1).name} stops publishing ${table} for realtime and nothing turns it back on`);
  }
}
if (!problems.length) ok(`realtime is turned on for ${LIVE.join(", ")} and never turned off`);

// ── row-level security, on every table the chat uses ─────────
const GUARDED = [
  "conversations",
  "conversation_participants",
  "messages",
  "read_receipts",
  "chat_files",
  "message_moderation",
];
const unguarded = GUARDED.filter(
  (t) => mentioning(new RegExp(`alter table public\\.${t} enable row level security`)).length === 0,
);
if (unguarded.length) {
  fail(`row-level security is never enabled on ${unguarded.join(", ")}`);
} else {
  ok(`row-level security is turned on for all ${GUARDED.length} tables the chat uses`);
}

const loosened = GUARDED.filter(
  (t) => mentioning(new RegExp(`alter table public\\.${t} disable row level security`)).length > 0,
);
if (loosened.length) {
  fail(`row-level security is turned off again on ${loosened.join(", ")}`);
} else {
  ok("and never turned off again");
}

// ── the four readers agree about a hidden message ────────────
// Each is read from the newest migration that defines it, because that is the
// definition the database is running.
const READERS = [
  ["the read policy", /create policy messages_read on public\.messages/],
  ["search_messages", /function public\.search_messages\(/],
  ["my_unread", /function public\.my_unread\(/],
  ["client_chat_mentions", /create or replace view public\.client_chat_mentions/],
];
const blind = [];
for (const [label, re] of READERS) {
  const file = newest(re);
  if (!file) {
    fail(`${label} is not defined in any migration`);
    continue;
  }
  const at = file.text.search(re);
  // The definition, not the whole file: a later function in the same migration
  // saying the clause would otherwise answer for this one.
  const end = file.text.indexOf("$$;", at);
  const body = file.text.slice(at, end < 0 ? file.text.length : end);
  if (!/hidden_at is null/.test(body)) blind.push(`${label} (${file.name})`);
}
if (blind.length) {
  fail(`${blind.join(", ")} would hand back a message Admin has taken down`);
} else {
  ok("all four places that read messages hide one that has been taken down");
}

// ── post_message has one signature, not two ──────────────────
// A defaulted parameter makes a second function in Postgres, which arrives
// with a new function's grants and leaves the old call ambiguous. The
// migration that adds the parameter has to drop the old one in the same file.
const post = newest(/create or replace function public\.post_message\(/);
if (!post) {
  fail("nothing defines post_message");
} else {
  const args = (post.text.match(/create or replace function public\.post_message\(([\s\S]*?)\)\s*returns/) ?? [])[1] ?? "";
  const params = (args.match(/^\s*p_\w+/gm) ?? []).length;
  const drops = (post.text.match(/drop function if exists public\.post_message\(/g) ?? []).length;
  if (params > 4 && drops === 0) {
    fail(`${post.name} gives post_message ${params} parameters and drops no earlier signature, so there are now two`);
  } else {
    ok(`post_message has one signature, and ${post.name} drops the one it replaced`);
  }
}

// ── the three rules the owner kept ───────────────────────────
const live = await readFile(new URL("../app/(app)/live-messaging.tsx", import.meta.url), "utf8");
// The pop-up carries who and the thread. The words only when the person has
// turned the preview on, which is off by default — so a screen somebody else
// can see does not show what a message about a client said.
//
// The first version of this asked whether the file mentioned the setting
// anywhere, which is a question near the rule: an import line satisfied it.
// What has to be true is narrower — every read of the arriving message's body
// is guarded by the preview setting, in the same expression.
const reads = [...live.matchAll(/\brow\.body\b/g)];
const unguardedReads = reads.filter((m) => {
  const line = live.slice(live.lastIndexOf("\n", m.index) + 1, live.indexOf("\n", m.index));
  const before = live.slice(Math.max(0, m.index - 200), m.index);
  return !/\.preview\b/.test(line) && !/\.preview\b[\s\S]{0,160}$/.test(before);
});
if (!live.includes("@/lib/chat-prefs")) {
  fail("the pop-up does not read the three Team chat settings at all");
} else if (reads.length === 0) {
  fail("the pop-up never reads the message, so the preview setting can do nothing");
} else if (unguardedReads.length > 0) {
  fail(`the pop-up reads the arriving message in ${unguardedReads.length} place(s) without asking whether the preview is on`);
} else if (!/\.dnd\b/.test(live)) {
  fail("the pop-up does not ask about do not disturb");
} else if (!/\.sound\b/.test(live)) {
  fail("nothing asks whether this person wanted a sound");
} else {
  ok("the pop-up shows the words only when the person has turned the preview on, and respects do not disturb");
}

// The three kinds and no fourth. Asking whether the three appear passed with
// a fourth appended to the list, which is the same bug as the preview check
// above: the question has to be what the list *is*, not what it contains.
const BY_REFERENCE = ["client_file", "form", "chat_file"];
const attach = newest(/function public\.post_message\(/);
const kinds = attach
  ? (attach.text.match(/\(v_item ->> 'kind'\) not in \(([^)]*)\)/) ?? [])[1]
  : undefined;
if (!attach || kinds === undefined) {
  fail("post_message does not say which kinds of attachment it takes, so it takes anything");
} else {
  const listed = [...kinds.matchAll(/'([^']+)'/g)].map((m) => m[1]);
  const extra = listed.filter((k) => !BY_REFERENCE.includes(k));
  const missing = BY_REFERENCE.filter((k) => !listed.includes(k));
  if (extra.length) {
    fail(`post_message also takes ${extra.join(", ")}, which is not a reference to anything`);
  } else if (missing.length) {
    fail(`post_message no longer takes ${missing.join(", ")}`);
  } else {
    ok("a file is attached by reference: a client document, a form, or a file sent in the thread");
  }
}

if (!newest(/function public\.remove_message\(/)) {
  fail("remove_message is gone, and taking your own words back is one of the rules kept");
} else {
  const rm = newest(/function public\.remove_message\(/);
  const at = rm.text.search(/function public\.remove_message\(/);
  const body = rm.text.slice(at, rm.text.indexOf("$$;", at));
  if (!/removed_at = now\(\)/.test(body) || /delete from public\.messages/.test(body)) {
    fail("remove_message deletes rather than leaving the marker");
  } else {
    ok("taking your own words back leaves the marker");
  }
}

console.log("");
if (problems.length) {
  for (const p of problems) console.error(`  FAILED  ${p}`);
  process.exit(1);
}
console.log("--- TEAM CHAT VERIFIED ---");
