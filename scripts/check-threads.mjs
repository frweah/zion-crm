/**
 * The client threads board, and calls (Communications brief, 23 November 2026).
 *
 * The database half of all this is `supabase/verify_the_threads_board.sql`,
 * which is run by hand because it needs credentials: a reply on any channel,
 * the groups, the consent dot per number, who may text, and the two functions
 * that write a call and collect a contact. Thirteen faults were put back
 * against it and thirteen were caught.
 *
 * This is the half that runs before every build, and it asks the three things
 * that script cannot:
 *
 *   1. the four vocabularies in lib/contact-methods.ts are the same four the
 *      migration gives the database. A screen cannot ask a plpgsql function
 *      what to put in a dropdown, so the lists are written twice - and two
 *      lists that are supposed to be one are two lists that drift;
 *   2. the tiles and the groups on the screen are the groups the function
 *      emits, and the screen does not decide a group for itself;
 *   3. nothing sends without a click, a role the policy refuses is not shown
 *      a send box, and which way a text went is `lastLine`'s answer.
 */
import { readFileSync } from "node:fs";
import {
  CONTACT_METHODS,
  CONTACT_NOTE_TYPES,
  NEEDS_METHOD,
  REAL_CONTACT_METHODS,
  isRealContact,
} from "../lib/contact-methods.ts";
import {
  CLOSED_GROUPS,
  GROUPS,
  TILES,
  CAN_LOG_CALLS,
  CAN_SEND_TEXTS,
  dots,
  firstLine,
  sendingTo,
  waited,
  whyNot,
} from "../lib/threads-board-shape.ts";
import { CAN_EDIT_CLIENTS, NOTE_TYPES } from "../lib/constants.ts";

const problems = [];
const bad = (line) => problems.push(line);
const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

const calls = read("supabase/migrations/0378_calls_get_a_home.sql");
const board = read("supabase/migrations/0379_the_client_threads_board.sql");
const activity = read("supabase/migrations/0381_a_call_reads_as_a_call.sql");

/**
 * The strings inside a SQL array literal, from the function that holds it.
 *
 * Read from the migration rather than from the database because this runs in
 * the deployment it would be asking about. The function is found by name and
 * the array by the `array[...]` that follows it, so a second function below
 * it cannot answer for the first.
 */
function sqlList(sql, fn) {
  const at = sql.indexOf(`function public.${fn}(`);
  if (at < 0) return null;
  const open = sql.indexOf("array[", at);
  const close = sql.indexOf("]", open);
  if (open < 0 || close < 0) return null;
  return [...sql.slice(open, close).matchAll(/'((?:[^']|'')+)'/g)].map((m) =>
    m[1].split("''").join("'"),
  );
}

const same = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);

// ── 1. the four vocabularies ──────────────────────────────────
{
  const inDb = sqlList(calls, "note_is_contact");
  if (!inDb) bad("0378 has no note_is_contact, so nothing says which notes must say how");
  else if (!same([...CONTACT_NOTE_TYPES], inDb)) {
    bad(`the contact note types differ: the screen says ${CONTACT_NOTE_TYPES.join(", ")}, the database says ${inDb.join(", ")}`);
  }

  const real = sqlList(calls, "is_real_contact");
  if (!real) bad("0378 has no is_real_contact, so the chip counts whatever is in the column");
  else if (!same([...REAL_CONTACT_METHODS], real)) {
    bad(`what counts as a contact differs: the screen says ${REAL_CONTACT_METHODS.join(", ")}, the database says ${real.join(", ")}`);
  }

  // The four a person picks, which the database holds as a check constraint
  // rather than a function.
  const constraint = calls.match(/notes_method_check[\s\S]{0,200}?array\[([^\]]+)\]/);
  const allowed = constraint
    ? [...constraint[1].matchAll(/'([^']+)'/g)].map((m) => m[1])
    : null;
  if (!allowed) bad("0378 does not constrain notes.method, so any word at all can be a method");
  else if (!same([...CONTACT_METHODS], allowed)) {
    bad(`the methods differ: the screen offers ${CONTACT_METHODS.join(", ")}, the database allows ${allowed.join(", ")}`);
  }

  // A phone call says how it happened by being one, so a form must not ask.
  if (NEEDS_METHOD.includes("Phone call")) {
    bad("the form asks how a Phone call happened, which the type has already said");
  }
  for (const type of CONTACT_NOTE_TYPES) {
    if (type !== "Phone call" && !NEEDS_METHOD.includes(type)) {
      bad(`${type} must say how it happened, and no form asks`);
    }
  }
  if (!/new\.method := 'Phone'/.test(calls)) {
    bad("nothing fills in the method for a Phone call, so the form has to ask after all");
  }
  // And every type the forms offer is a real note type.
  for (const type of CONTACT_NOTE_TYPES) {
    if (!NOTE_TYPES.includes(type)) bad(`"${type}" has to say how it happened and is not a note type`);
  }
  if (!isRealContact("Call") || isRealContact("End of day report") || isRealContact(null)) {
    bad("isRealContact does not agree with its own list");
  }
}

// ── 2. the groups and the tiles ───────────────────────────────
{
  // Every group the function can emit, from the case that emits them.
  const at = board.indexOf("end as grp");
  const head = board.slice(board.lastIndexOf("case", at), at);
  // `then 'x'` and the `else` at the end of it, which is how the last group
  // is filled - reading only the thens reported Up to date as a group nothing
  // ever puts a row in.
  const emitted = [...head.matchAll(/(?:then|else) '([a-z-]+)'/g)].map((m) => m[1]);
  const named = GROUPS.map((g) => g.key);
  for (const key of emitted) {
    if (!named.includes(key)) bad(`the function puts rows in "${key}" and the screen has no group for it`);
  }
  for (const key of named) {
    if (!emitted.includes(key)) bad(`the screen has a group "${key}" that the function never fills`);
  }
  if (emitted.length === 0) bad("no group is emitted by the board function, so every row would be ungrouped");

  // The six groups the brief names, in the order it names them.
  const expected = ["needs-reply", "approval", "stuck", "quiet", "stranger", "ok"];
  if (!same(named, expected)) {
    bad(`the groups are ${named.join(" · ")}, and the brief's order is ${expected.join(" · ")}`);
  }
  if (!same(CLOSED_GROUPS, ["ok"])) {
    bad(`${CLOSED_GROUPS.join(", ")} is folded away, and only Up to date should be`);
  }

  // Each tile holds the rows it says it does, and no tile holds everything.
  const row = (over = {}) => ({
    row_key: "x",
    grp: "ok",
    kind: "client",
    client_id: "c",
    client_name: "ZZ",
    client_no: 1,
    conversation_id: "v",
    update_id: null,
    who: "",
    numbers: [],
    channels: [],
    last_at: null,
    last_channel: null,
    last_sender_kind: null,
    last_sender: null,
    last_body: null,
    last_status: null,
    last_media_url: null,
    waiting_hours: null,
    quiet_days: 1,
    assigned_staff_id: null,
    assigned_name: null,
    unread: 0,
    next_scheduled: null,
    next_update: null,
    failed: 0,
    drafts: 0,
    consent_missing: false,
    opted_out: false,
    can_text: true,
    status: "Up to date",
    ...over,
  });

  const quiet = row({ grp: "quiet", quiet_days: 20 });
  const cases = [
    ["unanswered", row({ grp: "needs-reply", waiting_hours: 30 })],
    ["drafts", row({ kind: "draft", drafts: 1, update_id: "u" })],
    ["stuck", row({ grp: "stuck", failed: 2 })],
    ["quiet", quiet],
    ["consent", row({ consent_missing: true })],
    ["optout", row({ opted_out: true })],
  ];
  for (const [key, example] of cases) {
    const tile = TILES.find((t) => t.key === key);
    if (!tile) {
      bad(`there is no "${key}" tile, and the brief asks for one`);
      continue;
    }
    if (!tile.holds(example)) bad(`the ${tile.label} tile does not hold the row it is for`);
    const plain = row();
    if (tile.holds(plain)) bad(`the ${tile.label} tile holds a client with nothing wrong`);
  }
  if (TILES.length !== 6) bad(`${TILES.length} tiles, and the brief names six`);

  // The screen takes the group it is given rather than working one out.
  const screen = read("app/(app)/communication/threads/threads-board.tsx");
  if (/waiting_hours\s*(!==|>)\s*(null|0)\s*\?\s*"needs-reply"/.test(screen)) {
    bad("the board decides a group for itself, so the screen and the function can disagree");
  }
  if (!/r\.grp === group\.key/.test(screen)) {
    bad("the board does not group rows by the group the function gave them");
  }

  // Waiting, in words.
  if (waited(null) !== "" || waited(0) !== "under an hour") bad("a wait of nothing reads wrongly");
  if (waited(1) !== "1 hour" || waited(23) !== "23 hours") bad("hours are not said as hours");
  if (waited(24) !== "1 day" || waited(72) !== "3 days") bad("days are not said as days");
  if (firstLine("one\ntwo") !== "one") bad("the first line of a message is not its first line");
  if (firstLine("") !== "") bad("an empty message does not read as empty");
}

// ── 3. the panel, and who may send ────────────────────────────
{
  const panel = read("app/(app)/communication/threads/thread-panel.tsx");
  const actions = read("app/(app)/communication/threads/actions.ts");
  const record = read("app/(app)/clients/[id]/messages-tab.tsx");

  if (!same([...CAN_SEND_TEXTS], ["Admin", "Job Search", "Reports"])) {
    bad(`${CAN_SEND_TEXTS.join(", ")} are offered a send box, and the policy on sms_messages admits Admin, Job Search and Reports`);
  }
  // The roles that can write on a record but not text: the point of ruling 6c.
  const refused = CAN_EDIT_CLIENTS.filter((r) => !CAN_SEND_TEXTS.includes(r));
  if (refused.length === 0) {
    bad("no role can write on a record without being able to text, so ruling 6c is about nobody");
  }
  for (const role of refused) {
    if (!CAN_LOG_CALLS.includes(role)) {
      bad(`${role} cannot text and cannot log a call either, so they have nowhere to put one`);
    }
  }

  if (!/CAN_SEND_TEXTS\.includes\(role\)/.test(panel)) {
    bad("the panel does not ask whether this role may send before showing a box");
  }
  if (!/Log the call instead|Log a call/.test(panel)) {
    bad("a role that cannot text is not offered the thing it can do");
  }
  if (!/Log a call/.test(record)) {
    bad("the client record does not offer a call to a role that cannot text");
  }
  // Nothing sends by itself.
  if (/useEffect\([^)]*requestSubmit/.test(panel) || /autoSubmit/.test(panel)) {
    bad("something on the panel submits without being pressed");
  }
  // Every write goes through the actions file, and that file goes through the
  // one door that records a text before it sends it.
  // The call, not the word. Asserting that "sendClientSms" appears anywhere
  // in the file passes with the import left behind and the send replaced by a
  // direct insert, which is the one shape this is here to refuse.
  if (!/await sendClientSms\(supabase/.test(actions)) {
    bad("the panel sends a text without the door that records it before it goes");
  }
  if (/from\("sms_messages"\)\s*\n?\s*\.insert/.test(actions)) {
    bad("the panel writes a text row itself rather than through sendClientSms");
  }
  if (!/rpc\("log_a_call"/.test(actions)) bad("a call is not written by the function that writes both halves");
  if (!/rpc\("collect_contact"/.test(actions)) bad("adding to the month does not go through collect_contact");

  // Which way a text went is one answer, in one place.
  if (!/lastLine\(/.test(read("app/(app)/communication/threads/threads-board.tsx"))) {
    bad("the board decides for itself which way a text went");
  }
}

// ── 4. a call reads as a call ─────────────────────────────────
{
  const chips = read("app/(app)/clients/[id]/activity-tab.tsx");
  if (!/"Call",/.test(chips)) bad("the client record has no Calls chip");
  if (!/WHEN n\.method = 'Phone' THEN 'Call'/.test(activity)) {
    bad("the activity stream does not call a phone call a call, so the chip filters nothing");
  }
  const notes = read("app/(app)/clients/[id]/notes-tab.tsx");
  if (!/NEEDS_METHOD\.includes\(type\)/.test(notes)) bad("the note form does not ask how a contact happened");
  if (!/name="method"/.test(notes)) bad("the note form has no method field");
  const quick = read("app/(app)/quick-add.tsx");
  if (!/name="method"/.test(quick)) bad("the quick-add note cannot say how a contact happened");
  const addNote = read("app/(app)/clients/[id]/actions.ts");
  if (!/NEEDS_METHOD\.includes\(type\)/.test(addNote)) {
    bad("addNote does not refuse a contact note with no method, so the database refuses it instead");
  }
  // And the quick-add note carries a category, which addNote has always
  // required and quick-add never sent.
  const quickActions = read("app/(app)/quick-add-actions.ts");
  if (!/category: categoryForStage/.test(quickActions)) {
    bad("the quick-add note sends no category, so addNote refuses every one of them");
  }
}

// ── 5. the hub has four tabs ──────────────────────────────────
{
  const { NAV_GROUPS } = await import("../lib/roles.ts");
  const hub = NAV_GROUPS.find((g) => g.key === "inbox");
  if (!hub) bad("there is no Communication group");
  else {
    const labels = hub.items.map((i) => i.label);
    if (!same(labels, ["Client threads", "Mail", "Team chat", "Friday updates"])) {
      bad(`Communication offers ${labels.join(" · ")}, and ruling 1 names Client threads · Mail · Team chat · Friday updates`);
    }
  }
  const layout = read("app/(app)/layout.tsx");
  if (/TeamLink/.test(layout)) bad("Team still has a sidebar entry of its own (ruling 3)");
  if (!/TeamBubble|team-bubble/.test(layout)) bad("the team bubble has gone, and ruling 3 keeps it");
}

if (problems.length) {
  for (const p of problems) console.error(`  - ${p}`);
  console.error(`\n  FAILED  ${problems.length} problem(s) with the threads board`);
  process.exit(1);
}
console.log("  ok  the board's groups, the method vocabularies and who may send all agree");
