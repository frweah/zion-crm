import "server-only";

/**
 * Reading mail from Microsoft Graph, for the Mail screen (Messaging brief, M).
 *
 * Everything here is fetched live with the signed-in person's own token and
 * handed straight to the page. A message body is never written anywhere: not
 * to the database, not to a log, not to a cache (every request is no-store).
 * scripts/check-mail.mjs holds that line - this file may not import the
 * database client, and nothing that imports it may write.
 *
 * Bodies come back as plain text (Prefer: outlook.body-content-type="text").
 * An email's HTML is somebody else's markup; drawing it inside the CRM would
 * be running it here. Text cannot run.
 */

const GRAPH = "https://graph.microsoft.com/v1.0";

async function get<T>(token: string, path: string, headers: Record<string, string> = {}): Promise<T> {
  const response = await fetch(path.startsWith("http") ? path : `${GRAPH}${path}`, {
    headers: { Authorization: `Bearer ${token}`, ...headers },
    cache: "no-store",
  });
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const body = (await response.json()) as { error?: { message?: string } };
      detail = body.error?.message ?? detail;
    } catch {
      // the status says enough
    }
    throw new MailError(response.status, detail);
  }
  return (await response.json()) as T;
}

export class MailError extends Error {
  constructor(
    public status: number,
    detail: string,
  ) {
    super(
      status === 403 || status === 404
        ? "That mailbox or message is not yours to open. Access to a shared mailbox is given in Microsoft 365, not here."
        : `Microsoft said no (${status}): ${detail}`,
    );
  }
}

/** Whose mail: the person's own, or a shared mailbox they have been given in Exchange. */
export const rootOf = (mailbox: string | null) => (mailbox ? `/users/${encodeURIComponent(mailbox)}` : "/me");

export type Address = { name: string; address: string };

export type MessageSummary = {
  id: string;
  conversationId: string;
  subject: string;
  from: Address | null;
  to: Address[];
  cc: Address[];
  receivedAt: string;
  isRead: boolean;
  hasAttachments: boolean;
  preview: string;
  webLink: string;
};

type GraphRecipient = { emailAddress?: { name?: string; address?: string } };
type GraphMessage = {
  id: string;
  conversationId?: string;
  subject?: string;
  from?: GraphRecipient;
  toRecipients?: GraphRecipient[];
  ccRecipients?: GraphRecipient[];
  receivedDateTime?: string;
  isRead?: boolean;
  hasAttachments?: boolean;
  bodyPreview?: string;
  webLink?: string;
  body?: { contentType?: string; content?: string };
};

const addr = (r?: GraphRecipient): Address | null =>
  r?.emailAddress?.address ? { name: r.emailAddress.name ?? "", address: r.emailAddress.address.toLowerCase() } : null;

const summary = (m: GraphMessage): MessageSummary => ({
  id: m.id,
  conversationId: m.conversationId ?? "",
  subject: m.subject ?? "(no subject)",
  from: addr(m.from),
  to: (m.toRecipients ?? []).map(addr).filter((a): a is Address => Boolean(a)),
  cc: (m.ccRecipients ?? []).map(addr).filter((a): a is Address => Boolean(a)),
  receivedAt: m.receivedDateTime ?? "",
  isRead: Boolean(m.isRead),
  hasAttachments: Boolean(m.hasAttachments),
  preview: m.bodyPreview ?? "",
  webLink: m.webLink ?? "",
});

const LIST_FIELDS =
  "id,conversationId,subject,from,toRecipients,ccRecipients,receivedDateTime,isRead,hasAttachments,bodyPreview,webLink";

export const FOLDERS = { inbox: "inbox", sent: "sentitems" } as const;
export type Folder = keyof typeof FOLDERS;

/** A page of a folder, newest first, or a search across the mailbox. */
export async function listMessages(
  token: string,
  opts: { mailbox: string | null; folder: Folder; search?: string; top?: number },
): Promise<MessageSummary[]> {
  const top = String(opts.top ?? 40);
  const root = rootOf(opts.mailbox);
  if (opts.search?.trim()) {
    // $search reads the whole mailbox and cannot be ordered; Graph ranks it.
    const params = new URLSearchParams({ $search: `"${opts.search.replace(/"/g, "")}"`, $select: LIST_FIELDS, $top: top });
    const data = await get<{ value: GraphMessage[] }>(token, `${root}/messages?${params}`);
    return (data.value ?? []).map(summary);
  }
  const params = new URLSearchParams({ $select: LIST_FIELDS, $top: top, $orderby: "receivedDateTime desc" });
  const data = await get<{ value: GraphMessage[] }>(token, `${root}/mailFolders/${FOLDERS[opts.folder]}/messages?${params}`);
  return (data.value ?? []).map(summary);
}

/**
 * What in the inbox has not been read: how many, and the ones waiting longest
 * (the dashboard's "needs a reply", oldest first, and the Inbox badge -
 * 21 Sept 2026). Read only; nothing is marked read by being counted.
 *
 * Graph orders by a property only when the filter names it first, hence the
 * date condition that every message meets.
 */
export async function unreadInInbox(
  token: string,
  opts: { mailbox: string | null; top?: number },
): Promise<{ count: number; oldest: MessageSummary[] }> {
  const root = rootOf(opts.mailbox);
  const folder = await get<{ unreadItemCount?: number }>(token, `${root}/mailFolders/inbox?$select=unreadItemCount`);
  const count = folder.unreadItemCount ?? 0;
  if (!opts.top || count === 0) return { count, oldest: [] };
  const params = new URLSearchParams({
    $select: LIST_FIELDS,
    $top: String(opts.top),
    $filter: "receivedDateTime ge 1900-01-01T00:00:00Z and isRead eq false",
    $orderby: "receivedDateTime asc",
  });
  const data = await get<{ value: GraphMessage[] }>(token, `${root}/mailFolders/inbox/messages?${params}`);
  return { count, oldest: (data.value ?? []).map(summary) };
}

export type MessageDetail = MessageSummary & { bodyText: string };

/** One message, its body as text. Shown, never kept. */
export async function getMessage(token: string, mailbox: string | null, id: string): Promise<MessageDetail> {
  const params = new URLSearchParams({ $select: `${LIST_FIELDS},body` });
  const m = await get<GraphMessage>(token, `${rootOf(mailbox)}/messages/${encodeURIComponent(id)}?${params}`, {
    Prefer: 'outlook.body-content-type="text"',
  });
  return { ...summary(m), bodyText: m.body?.content ?? "" };
}

export type AttachmentInfo = { id: string; name: string; contentType: string; size: number; isInline: boolean };

/** What is attached - names and sizes only. The files themselves are opened through /api/mail/attachment. */
export async function listAttachments(token: string, mailbox: string | null, id: string): Promise<AttachmentInfo[]> {
  const params = new URLSearchParams({ $select: "id,name,contentType,size,isInline" });
  const data = await get<{ value: (AttachmentInfo & { "@odata.type"?: string })[] }>(
    token,
    `${rootOf(mailbox)}/messages/${encodeURIComponent(id)}/attachments?${params}`,
  );
  return (data.value ?? []).filter((a) => !a.isInline);
}

/** An attachment's bytes, straight from Graph to the person's browser. */
export async function fetchAttachment(
  token: string,
  mailbox: string | null,
  messageId: string,
  attachmentId: string,
): Promise<Response> {
  return fetch(
    `${GRAPH}${rootOf(mailbox)}/messages/${encodeURIComponent(messageId)}/attachments/${encodeURIComponent(attachmentId)}/$value`,
    { headers: { Authorization: `Bearer ${token}` }, cache: "no-store" },
  );
}
