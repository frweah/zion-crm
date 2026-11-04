/**
 * Who sent a text, and what its status should read as.
 *
 * No imports, for the reason `lib/report-shape.ts` has none: the Inbox and the
 * client's record both show these, and a check runs the rules over made-up
 * rows before every build. Two screens deciding separately what "In" means is
 * how the same text ends up described two ways (1a).
 */

export type TextLike = {
  direction: string;
  status: string;
  created_at: string;
  created_by?: string | null;
  kind?: string;
};

/**
 * The name to show beside a text.
 *
 * Outgoing is whoever wrote it, or the practice where a rule wrote it - a
 * reminder nobody typed is from the practice, and saying "Margaret" about it
 * would be wrong. Incoming is the client, named, because "from them" on a
 * screen listing four clients says nothing.
 */
export function senderOf(
  text: TextLike,
  clientName: string,
  senders: Record<string, string>,
): string {
  if (text.direction === "Incoming") {
    return clientName.trim() || "the client";
  }
  const who = text.created_by ? senders[text.created_by] : undefined;
  if (who) return who;
  // Reminders and system texts are the practice's, not a person's.
  return text.kind === "Reminder" || text.kind === "System" ? "the practice" : "the practice";
}

/**
 * What an outgoing text's status reads as right now.
 *
 * The sweep (0280) writes 'Not delivered' within a quarter of an hour, and a
 * screen should not wait for it: five minutes is the owner's figure and a
 * person looking at a list after five minutes should see the truth. So the
 * list works it out and the sweep writes it down, and they agree because the
 * five minutes is one number in one place.
 */
export const TEXT_LAPSE_MINUTES = 5;

export function statusOf(text: TextLike, now: Date = new Date()): string {
  if (text.direction === "Incoming") return text.status;
  if (text.status !== "Queued" && text.status !== "Sending") return text.status;
  const age = (now.getTime() - new Date(text.created_at).getTime()) / 60000;
  return age >= TEXT_LAPSE_MINUTES ? "Not delivered" : text.status;
}

/**
 * Whether a text can be retried: given up on, and the provider never took it.
 *
 * Takes the clock for the same reason `statusOf` does. Reading the real one
 * here would make this answer depend on when it was asked rather than on the
 * row, which is untestable and quietly wrong at the five-minute boundary.
 */
export function canRetry(
  text: TextLike & { provider_message_id?: string | null },
  now: Date = new Date(),
): boolean {
  const status = statusOf(text, now);
  if (status !== "Not delivered" && status !== "Failed") return false;
  // An id means the provider accepted it, so sending it again texts them twice.
  return !text.provider_message_id;
}

/**
 * The last line of a conversation, as the Inbox shows it (1a, 1b).
 *
 * Here rather than in the Inbox screen for the reason the rest of this file is
 * here: the client's Messages tab reads `sms_messages` and the Inbox reads the
 * mirror in `messages`, and two screens deciding separately what "from them"
 * means is how one text gets described two ways. A list that showed the words
 * alone could be read either way round, which is what 1a is about.
 */
export type LastLine = {
  /** 'client' and 'visitor' are them; 'staff' and 'system' are the practice. */
  sender_kind: string | null;
  sender: string | null;
  body: string | null;
  media_url: string | null;
};

export function lastLine(
  row: LastLine,
  them: string,
): { direction: "In" | "Out"; who: string; words: string } {
  const incoming = row.sender_kind === "client" || row.sender_kind === "visitor";
  const words =
    (row.body ?? "").trim() ||
    // A picture with no words in it is not an empty line. Said in words rather
    // than left to the thumbnail, because the thumbnail is a link to the
    // provider and a link that has gone takes the whole line with it.
    (row.media_url ? "a picture" : "");
  return {
    direction: incoming ? "In" : "Out",
    who: incoming
      ? them.trim() || "the client"
      : (row.sender ?? "").trim() || "the practice",
    words: words.length > 120 ? `${words.slice(0, 120)}…` : words,
  };
}
