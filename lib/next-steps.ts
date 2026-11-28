/**
 * What needs doing, as the screens read it.
 *
 * The rules are `public.next_steps` (0405) and nothing here decides anything.
 * What lives here is the two things a database cannot hold: the word a kind
 * is called on screen, and which colour a severity is.
 *
 * No imports. `scripts/check-next-steps.mjs` runs these over made-up input,
 * for the same reason the Twilio signature rules are importless: a vocabulary
 * that is only grepped for is a vocabulary that goes stale, and the one that
 * went stale here is the reason this file exists. The record's strip carried
 * its own `WORD` map covering six of the nine kinds the function could
 * return, so a fifth-shift item rendered the lowercase word "placement" on
 * screen and a stability item rendered "stability", for as long as either was
 * on anybody's record.
 */

export type NextStep = {
  /** Null for work that is nobody's client - an open task with no client on it. */
  client_id: string | null;
  /** When it is due or when it happens. Null for work that is simply outstanding. */
  when: string | null;
  what: string;
  /** Whose it is, by name, as far as the record knows. */
  who: string | null;
  kind: string;
  action_href: string;
  /** 1 overdue or today · 2 this week or holding up billing · 3 further off · 4 undated. */
  severity: number;
};

/**
 * The word a kind is called on screen.
 *
 * Three kinds share "Placement" on purpose: a fifth shift, thirty days of
 * stability and a retention check are three moments in one placement, and a
 * strip that labelled them three different nouns would be asking the reader
 * to learn the database's vocabulary.
 */
export const KIND_WORD: Record<string, string> = {
  reply: "Reply",
  task: "Task",
  authorization: "Authorization",
  form: "Billing",
  appointment: "Appointment",
  followup: "Follow-up",
  interview: "Interview",
  placement: "Placement",
  stability: "Placement",
  retention: "Placement",
  consent: "Consent",
  quiet: "Quiet",
};

/** The kinds this vocabulary knows. */
export const KINDS: string[] = Object.keys(KIND_WORD);

/**
 * A kind in words, always.
 *
 * A kind nobody has given a word to is sentence-cased rather than printed as
 * it is stored, so the worst a new kind can look is plain. The old map
 * printed the raw key, which is how "stability" reached a screen.
 */
export function kindWord(kind: string): string {
  const known = KIND_WORD[kind];
  if (known) return known;
  const word = (kind ?? "").replace(/[_-]+/g, " ").trim();
  if (!word) return "To do";
  return word.charAt(0).toUpperCase() + word.slice(1);
}

/** The label a count of this kind carries on a tile. */
export function kindCount(kind: string, n: number): string {
  const word = kindWord(kind);
  if (kind === "quiet") return n === 1 ? "1 client quiet" : `${n} clients quiet`;
  if (kind === "consent") return n === 1 ? "1 consent to record" : `${n} consents to record`;
  if (kind === "form") return n === 1 ? "1 form blocking billing" : `${n} forms blocking billing`;
  return n === 1 ? `1 ${word.toLowerCase()}` : `${n} ${word.toLowerCase()}s`;
}

/**
 * Severity as a chip class.
 *
 * One scale replacing four. 1 and 2 are both work for today or this week and
 * read as critical and warning; 3 and 4 are plain, because a chip that is
 * always coloured is a chip that says nothing.
 */
export function severityClass(severity: number | null | undefined): string {
  const s = Number(severity ?? 9);
  if (s <= 1) return "chip bad";
  if (s <= 2) return "chip warn";
  return "chip";
}

/** Whether this is work for today. Used for the tinting, and for the counts. */
export const dueNow = (step: NextStep): boolean => step.severity <= 1;

/**
 * The worst thing on a list, and how many there are.
 *
 * Ordered by severity and then by kind, so two things equally urgent come out
 * in the same order every time the page is drawn rather than in whatever
 * order the rows arrived.
 */
export function worstFirst(steps: NextStep[]): NextStep[] {
  return [...steps].sort(
    (a, b) => a.severity - b.severity || a.kind.localeCompare(b.kind) || a.what.localeCompare(b.what),
  );
}

/** One entry per kind present, worst kind first, for a strip of counts. */
export function byKind(steps: NextStep[]): { kind: string; n: number; worst: number }[] {
  const seen = new Map<string, { kind: string; n: number; worst: number }>();
  for (const s of steps) {
    const had = seen.get(s.kind);
    if (had) {
      had.n += 1;
      had.worst = Math.min(had.worst, s.severity);
    } else {
      seen.set(s.kind, { kind: s.kind, n: 1, worst: s.severity });
    }
  }
  return [...seen.values()].sort((a, b) => a.worst - b.worst || a.kind.localeCompare(b.kind));
}
