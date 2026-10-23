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
 * Deleting reaches the person's own mailbox and no other. It briefly reached
 * a shared one too (19-20 Sept 2026), until it turned out service@ is the
 * owner's own mailbox and is shared with nobody.
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
 * "Delete": into the person's own Deleted Items, as Outlook does, where it
 * can be got back. Never a permanent deletion, and never another mailbox.
 */
export async function moveToDeletedItems(token: string, messageId: string): Promise<void> {
  await post(token, `/me/messages/${encodeURIComponent(messageId)}/move`, { destinationId: "deleteditems" });
}

/**
 * What the CRM needs to know about a message it has just sent.
 *
 * Only the facts: the id, the thread, and the link. Not a word of the body,
 * which is why this can be handed to lib/mail-filing.ts.
 */
export type SentMessage = { id: string; conversationId: string; webLink: string; sentAt: string };

export type OutgoingWithFiles = Outgoing & {
  /** Graph fileAttachment objects, built in lib/mail-attach.ts. */
  attachments?: unknown[];
};

async function graph<T>(token: string, path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${GRAPH}${path}`, {
    ...init,
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", ...(init?.headers ?? {}) },
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
  return (response.status === 202 || response.status === 204 ? (null as T) : ((await response.json()) as T));
}

/**
 * Send a message and come back with the facts about it.
 *
 * `sendMail` answers 202 and says nothing, which is fine when nobody needs to
 * know what was sent - and useless now that a sent message has to be filed on
 * the client. So this writes a draft first, which Graph answers with an id
 * and a thread, and then sends the draft.
 *
 * Sending moves the message to Sent Items and may change its id, so the id to
 * file is the one in Sent Items. That copy is found by thread rather than
 * filtered for by id, because a `$filter` on conversationId with a sort is
 * the kind of query Exchange answers with "too complex". If it is not there
 * yet - indexing is quick but not instant - the draft's facts are filed
 * instead, with its thread, and the sweep files the Sent Items copy onto the
 * same client when it next runs. Two rows on one thread, both correctly on
 * the client, which is what the thread view shows as one conversation.
 */
export async function sendNewAndReport(token: string, m: OutgoingWithFiles): Promise<SentMessage> {
  const draft = await graph<{ id: string; conversationId: string; webLink: string }>(token, "/me/messages", {
    method: "POST",
    body: JSON.stringify({
      subject: m.subject,
      body: { contentType: "Text", content: m.text },
      toRecipients: recipients(m.to),
      ccRecipients: recipients(m.cc),
      ...(m.attachments?.length ? { attachments: m.attachments } : {}),
    }),
  });

  await graph<null>(token, `/me/messages/${encodeURIComponent(draft.id)}/send`, { method: "POST" });

  const sentAt = new Date().toISOString();
  try {
    const page = await graph<{ value: { id: string; conversationId: string; webLink: string; sentDateTime: string }[] }>(
      token,
      "/me/mailFolders/sentitems/messages?$select=id,conversationId,webLink,sentDateTime&$top=10&$orderby=sentDateTime desc",
    );
    const copy = page?.value?.find((v) => v.conversationId === draft.conversationId);
    if (copy) {
      return { id: copy.id, conversationId: copy.conversationId, webLink: copy.webLink ?? "", sentAt: copy.sentDateTime ?? sentAt };
    }
  } catch {
    // It went. Not finding the copy is not a reason to tell somebody it did
    // not, and the draft's thread is enough to file it on the client.
  }
  return { id: draft.id, conversationId: draft.conversationId, webLink: draft.webLink ?? "", sentAt };
}
