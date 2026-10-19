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
import { sourceFiles, prose, rel, readFile, withoutComments } from "./copy-text.mjs";

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
    test: /!/,
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
    name: "sells",
    test: /\b(seamless|effortless|powerful|smart|magic|magical|AI[- ]powered|journey)\b/i,
    why: "none of those words says anything a staff member can act on",
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


/* ── a title is a noun, and helper text is short ───────────── */
//
// Screens whose job is to explain, and the one group the design-language
// brief leaves alone. The same list check-words uses, for the same reason:
// judging them by a rule they are exempt from would be rewriting what the
// owner asked to stay put.
const EXPLAINERS = [
  "/billing/",
  "pending-authorizations",
  "hint-bar.tsx",
  "/sops/",
  "/paperwork/",
  "/login/",
  "/set-password/",
  "/auth/",
  "/admin/settings-hub/",
  "forms-and-checklists",
  // Compliance screens: the 1099 run, records requests, retention and the
  // books. Their helper text is what the IRS, the state and the practice's
  // own retention schedule require somebody to know before they act, which
  // is the test the standard sets - it changes what the person does next.
  "/admin/contractors/",
  "/admin/records-request/",
  "/admin/retention/",
  "/admin/documents/records-request/",
  "/books/",
  // Sent to rather than browsed to; it explains a thing being required of
  // somebody who has not met it before.
  "/security/two-factor",
];

/**
 * A verb in a heading, as far as a word list can tell.
 *
 * Deliberately a list rather than anything cleverer: a heading is three or
 * four words and the question is only whether it is a sentence in disguise.
 * A list that misses one is a heading that slips through, which is a smaller
 * harm than a check nobody can predict.
 */
const VERBS = /\b(is|are|was|were|be|been|being|has|have|had|do|does|did|can|cannot|will|would|should|must|may|might|add|adds|remove|removes|make|makes|made|take|takes|send|sends|sent|show|shows|open|opens|opened|close|closes|closed|go|goes|get|gets|put|puts|keep|keeps|say|says|read|reads|write|writes|sign|signs|signed|pay|pays|paid|move|moved|moves|need|needs|want|wants|use|uses|used|see|sees|look|looks|find|finds|work|works|run|runs|cover|covers|change|changes|start|starts|stop|stops|ask|asks|asked|tell|tells|give|gives|hold|holds|carry|carries|know|knows|come|comes|came|went|leave|leaves|left|log|logs|produces|reaches|counted)\b/i;

const HEADING_WORDS = 4;
const HELPER_WORDS = 12;

let headingHits = 0;
let helperHits = 0;

for (const url of await sourceFiles(APP, [".tsx"])) {
  const path = rel(url);
  if (EXPLAINERS.some((e) => path.includes(e))) continue;
  const src = withoutComments(await readFile(url, "utf8"));
  const lineAt = (i) => src.slice(0, i).split("\n").length;

  const headings = [
    ...src.matchAll(/<h[1-4][^>]*>([^<{}]+)<\/h[1-4]>/g),
    ...src.matchAll(/<PageHead[^>]*?\btitle="([^"{}]+)"/gs),
  ];
  for (const m of headings) {
    const text = m[1].replace(/\s+/g, " ").trim();
    if (!/[A-Za-z]{2}/.test(text)) continue;
    const words = text.split(/\s+/).length;
    if (words > HEADING_WORDS && VERBS.test(text)) {
      headingHits++;
      fail(`${path}:${lineAt(m.index)} the title "${text}" is a sentence. A title is a noun.`);
    }
  }

  for (const m of src.matchAll(/className="(?:sub|lock)"[^>]*>([^<{}]+)</g)) {
    const text = m[1].replace(/\s+/g, " ").trim();
    if (!/[A-Za-z]{2}/.test(text)) continue;
    const words = text.split(/\s+/).length;
    if (words > HELPER_WORDS) {
      helperHits++;
      fail(
        `${path}:${lineAt(m.index)} ${words} words of helper text — "${text.slice(0, 60)}…". ` +
          `Twelve or fewer, or it belongs in the hint or the knowledge base.`,
      );
    }
  }
}

if (headingHits === 0) ok("every title is a noun rather than a sentence");
if (helperHits === 0) ok(`no helper text runs past ${HELPER_WORDS} words`);

if (problems.length > 0) {
  console.error("");
  for (const p of problems) console.error(`  FAILED  ${p}`);
  console.error("");
  process.exit(1);
}

console.log("");
console.log("--- COPY VERIFIED ---");
