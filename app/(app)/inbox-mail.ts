"use server";

import { myMailAccess, resolveMailbox } from "@/lib/mail-access";
import { unreadInInbox } from "@/lib/mail";

export type MailWaiting =
  | { connected: false; count: 0; oldest: [] }
  | {
      connected: true;
      count: number;
      oldest: { id: string; subject: string; from: string; receivedAt: string; preview: string }[];
    };

/**
 * The person's own unread mail: how many for the Inbox badge, and the ones
 * waiting longest for the dashboard (21 Sept 2026).
 *
 * Its own file because of what mail is allowed to do (scripts/check-mail.mjs):
 * a file that reads mail writes nothing to the database, and opens a mailbox
 * only through resolveMailbox. This reads the person's own, and only reads -
 * nothing is marked read by being counted.
 */
export async function mailWaiting(top = 0): Promise<MailWaiting> {
  const access = await myMailAccess();
  if (!access.ok) return { connected: false, count: 0, oldest: [] };
  const mailbox = resolveMailbox(access, "me");
  if (mailbox === false) return { connected: false, count: 0, oldest: [] };
  try {
    const { count, oldest } = await unreadInInbox(access.token, { mailbox, top });
    return {
      connected: true,
      count,
      oldest: oldest.map((m) => ({
        id: m.id,
        subject: m.subject || "(no subject)",
        from: m.from?.name || m.from?.address || "",
        receivedAt: m.receivedAt,
        preview: m.preview.slice(0, 140),
      })),
    };
  } catch {
    // Outlook not answering is not a reason for the dashboard not to load.
    return { connected: false, count: 0, oldest: [] };
  }
}
