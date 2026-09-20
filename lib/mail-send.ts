import "server-only";

/**
 * Sending mail, as the signed-in person (Messaging brief, M) - and moving a
 * message of their own to Deleted Items.
 *
 * The only file that calls Graph's send, reply, forward or move, and it is
 * called only from the Send, Reply, Forward and Delete actions in
 * app/(app)/mail/actions.ts -
 * scripts/check-mail.mjs fails the build otherwise. Nothing sends on a timer,
 * on a trigger, or on anybody's behalf.
 *
 * Always sent from /me: delegated Mail.Send reaches only the mailbox of
 * whoever consented. A reply to a message in the shared mailbox is sent from
 * the person's own address, quoting it, because sending as service@ would
 * need Mail.Send.Shared, which the CRM does not ask for.
 *
 * Deleting is the one thing that reaches another mailbox, and only ever as a
 * move to that mailbox's own Deleted Items (owner, 19 Sept 2026). Nothing
 * here is recorded in the CRM: the files that touch mail may not write to the
 * database at all - that is what keeps a message body out of it
 * (scripts/check-mail.mjs) - so the record of who cleared the shared mailbox
 * is Exchange's own, where a shared mailbox is audited anyway.
 *
 * Plain text. The body is sent and not kept.
 */

const GRAPH = "https://graph.microsoft.com/v1.0";

async function post(token: string, path: string, body: unknown): Promise<void> {
  const response = await fetch(`${GRAPH}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    cache: "no-store",
  });
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const data = (await response.json()) as { error?: { message?: string } };
      detail = data.error?.message ?? detail;
    } catch {
      // the status says enough
    }
    if (response.status === 403) {
      throw new Error("Microsoft refused. This needs the permission that comes with turning sending on - use “Turn sending on” on the Mail screen and reconnect once.");
    }
    throw new Error(`Microsoft did not send it (${response.status}): ${detail}`);
  }
}

const recipients = (list: string[]) => list.map((address) => ({ emailAddress: { address } }));

export type Outgoing = { to: string[]; cc: string[]; subject: string; text: string };

/** A new message from the person's own mailbox, kept in their Sent Items. */
export async function sendNew(token: string, m: Outgoing): Promise<void> {
  await post(token, "/me/sendMail", {
    message: {
      subject: m.subject,
      body: { contentType: "Text", content: m.text },
      toRecipients: recipients(m.to),
      ccRecipients: recipients(m.cc),
    },
    saveToSentItems: true,
  });
}

/** A reply to a message in the person's own mailbox, threaded by Outlook. */
export async function replyOwn(token: string, messageId: string, text: string, all: boolean): Promise<void> {
  await post(token, `/me/messages/${encodeURIComponent(messageId)}/${all ? "replyAll" : "reply"}`, { comment: text });
}

/** Forward a message from the person's own mailbox. */
export async function forwardOwn(token: string, messageId: string, to: string[], text: string): Promise<void> {
  await post(token, `/me/messages/${encodeURIComponent(messageId)}/forward`, { comment: text, toRecipients: recipients(to) });
}

/**
 * "Delete": into Deleted Items, as Outlook does, where it can be got back.
 * Never a permanent deletion.
 *
 * Without a mailbox it is the person's own. With one it is a shared mailbox
 * they have been offered, and the message goes to that mailbox's Deleted
 * Items rather than to theirs - service@'s mail stays service@'s, including
 * after somebody has finished with it.
 */
export async function moveToDeletedItems(token: string, messageId: string, mailbox?: string | null): Promise<void> {
  const root = mailbox ? `/users/${encodeURIComponent(mailbox)}` : "/me";
  await post(token, `${root}/messages/${encodeURIComponent(messageId)}/move`, { destinationId: "deleteditems" });
}
