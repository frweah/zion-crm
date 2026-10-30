/**
 * The three settings a person has over Team chat.
 *
 * Kept out of the server action and out of the client component so both read
 * the same list, and so the check script can read it without loading either.
 *
 * Every one of them is off unless there is a row saying otherwise, which makes
 * the quiet behaviour the default:
 *
 *   `chat:preview` decides whether the pop-up carries the first line of the
 *   message or only who sent it and which thread. Off, because a message may
 *   be about a client and the screen may be in a room with somebody who should
 *   not read it. This is the setting the rule turns on, not a rule the setting
 *   replaces.
 *
 *   `chat:sound` is a sound when a message arrives. Off, as the brief asks.
 *
 *   `chat:dnd` stops the pop-up and the desktop notification. The unread count
 *   stays, because do-not-disturb is about not being interrupted and not about
 *   not being told.
 */
export const CHAT_PREFS = ["chat:preview", "chat:sound", "chat:dnd"] as const;

export type ChatPref = (typeof CHAT_PREFS)[number];

export type ChatSettings = {
  preview: boolean;
  sound: boolean;
  dnd: boolean;
};

/** What the three say, given whatever rows this person has. */
export function chatSettings(rows: { key: string }[]): ChatSettings {
  const has = (k: ChatPref) => rows.some((r) => r.key === k);
  return {
    preview: has("chat:preview"),
    sound: has("chat:sound"),
    dnd: has("chat:dnd"),
  };
}

/** What each one says on screen. A label is what it does, not what it is. */
export const CHAT_PREF_LABELS: Record<ChatPref, string> = {
  "chat:preview": "Show the message in the pop-up",
  "chat:sound": "Make a sound",
  "chat:dnd": "Do not disturb",
};
