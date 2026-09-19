/**
 * The bridge to Teams.
 *
 * Chat inside the CRM is where a conversation about a client belongs: it is on
 * the client's record, it is exported with it, and a restricted document
 * cannot be sent to somebody who may not open it. Teams is where the rest of
 * the day happens, and people are already in it - so every place the CRM
 * offers a conversation also offers the same conversation in Teams, rather
 * than pretending the other window is not open.
 *
 * A deep link only: no Teams message is ever sent from here, and nothing said
 * in Teams comes back. Anything that has to be on the record is said here.
 */
export function teamsChatHref(emails: (string | null | undefined)[]): string | null {
  const people = emails.filter((e): e is string => Boolean(e && e.includes("@")));
  if (people.length === 0) return null;
  return `https://teams.microsoft.com/l/chat/0/0?users=${encodeURIComponent(people.join(","))}`;
}
