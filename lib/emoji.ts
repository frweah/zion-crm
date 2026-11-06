/**
 * Emoji in Team chat (owner, 6 Nov 2026).
 *
 * The screen standard says no emoji, and this does not break it. That rule is
 * about what the practice says to a person: a heading with a sparkle on it, a
 * button with a tick instead of a word. These are what one colleague says to
 * another in a message they typed themselves, which is the one place on the
 * screen where the words are not the practice's.
 *
 * **Stored as plain Unicode**, which is the whole of why there is nothing
 * clever here. A message body is text, search reads it, the nightly digest
 * puts it in an email and a notification shows it - so a thumbs up has to be
 * the character and not `:+1:`, not an image, not a span with a class on it.
 * Nothing in the database or in the mail path knows this feature exists.
 *
 * ── the list ────────────────────────────────────────────────
 *
 * Short on purpose. A full set is two thousand characters behind a search box,
 * which is a thing to browse rather than a thing to reach for, and most of it
 * is of no use to a practice talking about appointments and paperwork. These
 * are the ones that get used at work, grouped the way somebody looks for
 * them, with the names people already type from elsewhere.
 */
export type EmojiGroup = { name: string; emoji: { char: string; codes: string[] }[] };

export const EMOJI: EmojiGroup[] = [
  {
    name: "Yes and no",
    emoji: [
      { char: "👍", codes: ["+1", "thumbsup", "yes"] },
      { char: "👎", codes: ["-1", "thumbsdown", "no"] },
      { char: "✅", codes: ["white_check_mark", "done", "tick"] },
      { char: "❌", codes: ["x", "cross"] },
      { char: "🙏", codes: ["pray", "thanks", "please"] },
      { char: "👏", codes: ["clap", "well_done"] },
      { char: "🤝", codes: ["handshake", "agreed"] },
      { char: "👀", codes: ["eyes", "looking"] },
    ],
  },
  {
    name: "How it is going",
    emoji: [
      { char: "🙂", codes: ["slightly_smiling_face", "smile"] },
      { char: "😄", codes: ["smile_big", "grin", "happy"] },
      { char: "😅", codes: ["sweat_smile", "phew"] },
      { char: "😐", codes: ["neutral_face", "hmm"] },
      { char: "🙁", codes: ["slightly_frowning_face", "sad"] },
      { char: "😬", codes: ["grimacing", "awkward"] },
      { char: "🤔", codes: ["thinking", "thinking_face"] },
      { char: "😴", codes: ["sleeping", "tired"] },
    ],
  },
  {
    name: "The work",
    emoji: [
      { char: "📅", codes: ["calendar", "date"] },
      { char: "📞", codes: ["telephone", "call", "phone"] },
      { char: "📧", codes: ["email", "mail"] },
      { char: "📄", codes: ["page", "document", "form"] },
      { char: "📝", codes: ["memo", "note", "writing"] },
      { char: "💰", codes: ["money", "moneybag", "paid"] },
      { char: "⏰", codes: ["alarm_clock", "reminder", "due"] },
      { char: "🚗", codes: ["car", "drive", "travel"] },
      { char: "🏢", codes: ["office", "building", "employer"] },
      { char: "🎉", codes: ["tada", "hired", "celebrate"] },
    ],
  },
  {
    name: "Worth a look",
    emoji: [
      { char: "⚠️", codes: ["warning", "careful"] },
      { char: "❗", codes: ["exclamation", "urgent"] },
      { char: "❓", codes: ["question", "query"] },
      { char: "🔥", codes: ["fire", "on_fire"] },
      { char: "⭐", codes: ["star", "good"] },
      { char: "💡", codes: ["bulb", "idea"] },
      { char: "🔗", codes: ["link"] },
      { char: "📌", codes: ["pushpin", "pinned"] },
    ],
  },
];

/** Every `:name:` that means something, to the character it means. */
export const BY_CODE: Record<string, string> = Object.fromEntries(
  EMOJI.flatMap((g) => g.emoji.flatMap((e) => e.codes.map((c) => [c, e.char] as const))),
);

/**
 * `:tada:` becomes the character; anything else is left exactly as typed.
 *
 * Only names on the list above, which is what keeps this safe to run over
 * every message: "the 9:30 appointment:" has colons in it and no name
 * between them that this knows, so it comes out unchanged. A name is letters,
 * digits, `_`, `+` and `-`, so the pattern cannot run across a sentence.
 */
export function expandShortcodes(text: string): string {
  return text.replace(/:([a-z0-9_+-]{1,24}):/gi, (whole, code: string) => BY_CODE[code.toLowerCase()] ?? whole);
}

/** Whether anything in this text would change, so a composer can leave it alone. */
export function hasShortcode(text: string): boolean {
  return expandShortcodes(text) !== text;
}
