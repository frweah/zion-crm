/**
 * The words on a screen, checked (CLAUDE.md, "Writing and screen standard").
 *
 *   node scripts/check-copy.mjs        (also runs before every `npm run build`)
 *
 * scripts/check-words.mjs already holds the two rules about length: an empty
 * state is one sentence, and a working screen carries no paragraph. This
 * holds the rules about voice and about accuracy, which are the two ways copy
 * goes wrong without getting longer.
 *
 * The one with teeth is the last: **a screen named in copy has to exist.**
 * The navigation was regrouped twice - Dashboard became Home and Inbox became
 * Communication on 21 Sept, Clients came out of Work on 15 Oct - and the
 * sentences pointing at those screens were not regrouped with them. Four of
 * them were still telling staff to go to "Dashboard → Tasks", "Inbox → Mail"
 * and "Billing → Invoices", and Invoices had been deleted outright. Nothing
 * was broken, which is exactly why nobody noticed: the links worked, and only
 * the words were wrong.
 *
 * What is deliberately not judged:
 *
 *   Comments. The house style is long comments explaining why, and a rule
 *   written for a button applied to one of those is nonsense.
 *
 *   The public website chat. "Please start a new one" is addressed to a
 *   member of the public rather than to a colleague, and courtesy to a
 *   stranger is not the same thing as padding on a working screen.
 *
 *   Anything assembled at runtime, for the reason copy-text.mjs gives.
 */
import { NAV_GROUPS } from "../lib/roles.ts";
import { sourceFiles, prose, rel, readFile } from "./copy-text.mjs";

const APP = new URL("../app/", import.meta.url);
const problems = [];
const ok = (m) => console.log(`  ok  ${m}`);
const fail = (m) => problems.push(m);

/** Screens that speak to the public rather than to a colleague. */
const PUBLIC = ["app/api/widget/", "app/(app)/admin/system/web-chat"];

/* ── the voice ─────────────────────────────────────────────── */
const VOICE = [
  {
    name: "asks rather than tells",
    test: /\bplease\b/i,
    why: 'the house voice is direct: "Say why it is being reopened", not "Please give a reason"',
  },
  {
    name: "apologises",
    test: /\b(sorry|oops|unfortunately|whoops)\b/i,
    why: "a screen says what happened and what to do about it, and does not apologise",
  },
  {
    name: "exclaims",
    test: /\w!(\s|$)/,
    why: "nothing on a working screen is exciting enough for an exclamation mark",
  },
  {
    name: "asks if somebody is sure",
    test: /are you sure/i,
    why: 'a confirmation names the thing: "Remove this line?" rather than "Are you sure?"',
  },
  {
    name: "says click",
    test: /\bclick (here|the)\b/i,
    why: "the words say what happens, not what to do with the mouse",
  },
  {
    name: "leaks the machinery",
    test: /\b(RLS|RPC|UUID|supabase|postgres|stack trace|null pointer)\b/i,
    why: "a person reads about their work, not about ours",
  },
];

/* ── labels and buttons ────────────────────────────────────── */
const BARE = /^(ok|okay|submit|yes|no|done it|go)$/i;

/* ── a screen named in copy exists ─────────────────────────── */
const groups = new Map(NAV_GROUPS.map((g) => [g.label.toLowerCase(), g]));
const screens = new Set();
for (const g of NAV_GROUPS) for (const i of g.items) screens.add(i.label.toLowerCase());

/** "Group → Screen", as the copy writes a place to go. */
const CROSS = /([A-Z][A-Za-z&'’-]*(?: [A-Za-z&'’-]+){0,3})\s*(?:→|->|›)\s*([A-Z][A-Za-z&'’-]*(?: [A-Za-z&'’-]+){0,3})/g;

let voiceHits = 0;
let crossSeen = 0;
let labelsSeen = 0;

for (const url of await sourceFiles(APP, [".tsx", ".ts"])) {
  const path = rel(url);
  const isPublic = PUBLIC.some((p) => path.includes(p));
  const src = await readFile(url, "utf8");

  for (const found of prose(src, path)) {
    const { text, line } = found;

    if (!isPublic) {
      for (const rule of VOICE) {
        if (rule.test.test(text)) {
          voiceHits++;
          fail(`${path}:${line} ${rule.name} — "${text.slice(0, 80)}". ${rule.why}.`);
        }
      }
    }

    // A screen named in copy has to be one that exists.
    for (const m of text.matchAll(CROSS)) {
      crossSeen++;
      const group = m[1].trim();
      const screen = m[2].trim();
      // The group half is often the tail of a sentence ("...on Clients"), so
      // only its last words can be the name; try the longest that is one.
      const words = group.split(" ");
      const named = words.some((_, i) => groups.has(words.slice(i).join(" ").toLowerCase()));
      if (!named) {
        fail(
          `${path}:${line} names "${group} → ${screen}", and there is no ${group.split(" ").pop()} group in the sidebar.`,
        );
      } else if (!screens.has(screen.toLowerCase())) {
        fail(`${path}:${line} names "${group} → ${screen}", and there is no ${screen} screen.`);
      }
    }
  }

  // A button says what happens.
  for (const m of src.matchAll(/<button\b[^>]*>([^<{}]+)<\/button>/g)) {
    const text = m[1].replace(/\s+/g, " ").trim();
    if (!/[A-Za-z]{2}/.test(text)) continue;
    labelsSeen++;
    if (BARE.test(text)) {
      fail(`${path} has a button labelled "${text}". A button says what pressing it does.`);
    }
    if (/\.$/.test(text)) {
      fail(`${path} has a button labelled "${text}" with a full stop. A button is a label, not a sentence.`);
    }
  }
}

if (voiceHits === 0) ok(`the voice holds across every screen (${VOICE.length} rules)`);
if (!problems.some((p) => p.includes("→"))) {
  ok(`all ${crossSeen} places a screen is named in copy point at a screen that exists`);
}
if (!problems.some((p) => p.includes("button labelled"))) {
  ok(`all ${labelsSeen} buttons say what pressing them does`);
}

if (problems.length > 0) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log("--- COPY VERIFIED ---");
