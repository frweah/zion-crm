"use server";

import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { myMailAccess, resolveMailbox } from "@/lib/mail-access";
import { getCurrentStaff } from "@/lib/session";
import { getMessage, fetchAttachment, listAttachments } from "@/lib/mail";
import { sendNew, replyOwn, forwardOwn, moveToDeletedItems, sendNewAndReport } from "@/lib/mail-send";
import { attachmentsFromStorage } from "@/lib/mail-attach";
import {
  addressesBelongingToAnotherClient,
  documentPaths,
  fileOnClient,
  keepAttachmentOnClient,
  logSentOnClient,
  recipientsForClient,
  setThreadRestricted,
  unfileFromClient,
} from "@/lib/mail-filing";

/**
 * Send, Reply, Forward - the only three things in the CRM that use Mail.Send,
 * each run by the person pressing its button (Messaging brief, M) - and
 * Delete, which moves a message of their own to Deleted Items. Nothing is
 * written to the database here: the message goes to Microsoft and is kept in
 * the person's own Sent Items, and the nightly sweep logs it on a client or
 * counselor record exactly as it logs any other mail - subject, date,
 * direction, link.
 */
export type SendState = { error: string | null; ok: string | null };

const ADDRESS = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

/**
 * A link into the CRM, which is what a form in an email must never be.
 *
 * The practice's own host, the portal, and anything that looks like a signed
 * storage link. A counselor who gets a link gets something that stops working
 * before they open it; the document itself does not.
 */
const FORM_LINK = /crm\.zionvocrehab\.com|zion-crm[\w-]*\.vercel\.app|\/portal\/|supabase\.co\/storage/i;

function addresses(raw: string): { list: string[]; bad: string[] } {
  const list: string[] = [];
  const bad: string[] = [];
  for (const part of raw.split(/[,;\s]+/).map((p) => p.trim()).filter(Boolean)) {
    if (ADDRESS.test(part)) list.push(part.toLowerCase());
    else bad.push(part);
  }
  return { list: [...new Set(list)], bad };
}

async function sender() {
  const access = await myMailAccess();
  if (!access.ok) return { error: access.message } as const;
  if (!access.canSend) {
    return { error: "Sending is not turned on for your Outlook yet. Use “Turn sending on” on the Mail screen." } as const;
  }
  return { access } as const;
}

export async function sendMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const s = await sender();
  if ("error" in s) return { error: s.error ?? "Not allowed.", ok: null };

  const to = addresses(String(formData.get("to") ?? ""));
  const cc = addresses(String(formData.get("cc") ?? ""));
  const subject = String(formData.get("subject") ?? "").trim();
  const text = String(formData.get("text") ?? "");
  if (to.bad.length || cc.bad.length) return { error: `Not an address: ${[...to.bad, ...cc.bad].join(", ")}.`, ok: null };
  if (to.list.length === 0) return { error: "Who is it to?", ok: null };
  if (!subject) return { error: "Give it a subject.", ok: null };
  if (!text.trim()) return { error: "The message is empty.", ok: null };

  try {
    await sendNew(s.access.token, { to: to.list, cc: cc.list, subject, text });
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not sent.", ok: null };
  }
  return { error: null, ok: `Sent from ${s.access.email}.` };
}

export async function replyMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const s = await sender();
  if ("error" in s) return { error: s.error ?? "Not allowed.", ok: null };

  const id = String(formData.get("message_id") ?? "");
  const all = formData.get("all") === "yes";
  const text = String(formData.get("text") ?? "");
  const mailbox = resolveMailbox(s.access, String(formData.get("box") ?? ""));
  if (mailbox === false) return { error: "That mailbox is not yours to reply from.", ok: null };
  if (!id) return { error: "Which message?", ok: null };
  if (!text.trim()) return { error: "The reply is empty.", ok: null };

  try {
    if (mailbox === null) {
      await replyOwn(s.access.token, id, text, all);
    } else {
      // A shared-mailbox message: answered from the person's own address,
      // quoting it, since the CRM does not send as the shared mailbox.
      const original = await getMessage(s.access.token, mailbox, id);
      const to = original.from ? [original.from.address] : [];
      const cc = all
        ? [...original.to, ...original.cc].map((a) => a.address).filter((a) => a !== mailbox && !to.includes(a))
        : [];
      if (to.length === 0) return { error: "The message has no sender to reply to.", ok: null };
      await sendNew(s.access.token, {
        to,
        cc,
        subject: /^re:/i.test(original.subject) ? original.subject : `RE: ${original.subject}`,
        text: `${text}\n\n-----\nOn ${original.receivedAt}, ${original.from?.name || original.from?.address} wrote to ${mailbox}:\n\n${original.bodyText}`,
      });
    }
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not sent.", ok: null };
  }
  return { error: null, ok: mailbox ? `Replied from ${s.access.email}.` : "Replied." };
}

export async function forwardMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const s = await sender();
  if ("error" in s) return { error: s.error ?? "Not allowed.", ok: null };

  const id = String(formData.get("message_id") ?? "");
  const to = addresses(String(formData.get("to") ?? ""));
  const text = String(formData.get("text") ?? "");
  const mailbox = resolveMailbox(s.access, String(formData.get("box") ?? ""));
  if (mailbox === false) return { error: "That mailbox is not yours to forward from.", ok: null };
  if (to.bad.length) return { error: `Not an address: ${to.bad.join(", ")}.`, ok: null };
  if (to.list.length === 0) return { error: "Forward it to whom?", ok: null };

  try {
    if (mailbox === null) {
      await forwardOwn(s.access.token, id, to.list, text);
    } else {
      const original = await getMessage(s.access.token, mailbox, id);
      await sendNew(s.access.token, {
        to: to.list,
        cc: [],
        subject: /^fw:/i.test(original.subject) ? original.subject : `FW: ${original.subject}`,
        text: `${text}\n\n-----\nFrom: ${original.from?.name || ""} <${original.from?.address ?? ""}>\nSent: ${original.receivedAt}\nTo: ${mailbox}\nSubject: ${original.subject}\n\n${original.bodyText}`,
      });
    }
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not forwarded.", ok: null };
  }
  return { error: null, ok: "Forwarded." };
}

/**
 * Delete (owner, 19 Sept 2026): moves a message in the person's own mailbox
 * to their Deleted Items, as Outlook's Delete does - it can be got back
 * there, and a message already logged on a record stays logged.
 *
 * Not offered for a shared mailbox. It was for a day (20 Sept 2026), until
 * service@ turned out to be the owner's own mailbox, shared with nobody.
 */
export async function deleteMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const access = await myMailAccess();
  if (!access.ok) return { error: access.message, ok: null };
  if (!access.canDelete) {
    return { error: "Deleting is not turned on for your Outlook yet. Use “Turn sending on” on the Mail screen.", ok: null };
  }
  const mailbox = resolveMailbox(access, String(formData.get("box") ?? ""));
  if (mailbox !== null) return { error: "Messages in a shared mailbox are deleted in Outlook, not here.", ok: null };
  const id = String(formData.get("message_id") ?? "");
  if (!id) return { error: "Which message?", ok: null };

  try {
    await moveToDeletedItems(access.token, id);
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not deleted.", ok: null };
  }
  const back = String(formData.get("back") ?? "/mail");
  redirect(back.startsWith("/mail") ? back : "/mail");
}

/**
 * A message about a client, from the record (owner, 23 Oct 2026).
 *
 * The difference from Send is not the sending - that is the same Graph call
 * from the same person's mailbox - it is that the practice keeps the fact of
 * it. The message is filed on the client the moment it goes, so everybody who
 * can see the client can see that it was written, and a line goes in the
 * contact log saying who wrote to whom about what.
 *
 * Three rules the owner set, in the order they are checked:
 *
 *   The client is written to at the address on their record and no other. An
 *   address typed into a box is how a client's business reaches the wrong
 *   person with the same surname, so a recipient that belongs to any client
 *   has to be this client's own.
 *
 *   A form goes as an attachment, never as a link. A counselor with a link
 *   has a link that expires, in an email they may read in a month.
 *
 *   Documents are attached from the client's file, which means the person
 *   sending one has to be allowed to open it - the storage policy answers
 *   that, not this action.
 */
export async function sendClientMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const s = await sender();
  if ("error" in s) return { error: s.error ?? "Not allowed.", ok: null };

  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  if (!clientId) return { error: "Which client is this about?", ok: null };

  const picked = formData.getAll("to").map((v) => String(v).trim().toLowerCase()).filter(Boolean);
  const typed = addresses(String(formData.get("cc") ?? ""));
  const subject = String(formData.get("subject") ?? "").trim();
  const text = String(formData.get("text") ?? "");
  const documents = formData.getAll("doc").map((v) => String(v)).filter(Boolean);

  if (typed.bad.length) return { error: `Not an address: ${typed.bad.join(", ")}.`, ok: null };
  if (picked.length === 0) return { error: "Who is it to?", ok: null };
  if (!subject) return { error: "Give it a subject.", ok: null };
  if (!text.trim()) return { error: "The message is empty.", ok: null };

  const { clientAddress, clientName } = await recipientsForClient(clientId);

  // Writing to the client: their own address, the one on their record.
  const everyone = [...picked, ...typed.list];
  const wrong = await addressesBelongingToAnotherClient(everyone, clientAddress);
  if (wrong.length > 0) {
    return {
      error: `${wrong[0]} is another client's address — a client is written to at the address on their own record.`,
      ok: null,
    };
  }

  if (FORM_LINK.test(text)) {
    return { error: "A form goes as an attachment, not a link — attach it from the client's documents.", ok: null };
  }

  const files = await documentPaths(clientId, documents);
  if (files.length !== documents.length) {
    return { error: "One of those documents is not on this client's record any more.", ok: null };
  }
  const built = await attachmentsFromStorage(files);
  if (built.error) return { error: built.error, ok: null };

  let sent;
  try {
    sent = await sendNewAndReport(s.access.token, {
      to: picked,
      cc: typed.list,
      subject,
      text,
      attachments: built.attachments,
    });
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not sent.", ok: null };
  }

  // It has gone. From here nothing can be undone, so a failure to file says
  // so plainly rather than implying the message did not go.
  const filed = await fileOnClient(
    clientId,
    [
      {
        id: sent.id,
        conversation: sent.conversationId,
        subject,
        sent_at: sent.sentAt,
        direction: "Outgoing",
        counterpart: picked[0],
        web_link: sent.webLink,
        mailbox: "",
      },
    ],
    null,
    "sent",
  );
  const logged = await logSentOnClient({
    clientId,
    staffId: me.id,
    subject,
    to: picked,
    cc: typed.list,
  });

  revalidatePath(`/clients/${clientId}`);
  if (filed.error || logged.error) {
    return {
      error: `It was sent, and ${filed.error ?? logged.error}`,
      ok: null,
    };
  }
  return { error: null, ok: `Sent to ${picked.join(", ")} and filed on ${clientName}.` };
}

/**
 * File a message, or its whole thread, onto a client (owner, 23 Oct 2026).
 *
 * The facts are read from Microsoft here rather than taken from the form. The
 * screen knows the subject and the sender because it has just shown them, but
 * a form can be edited before it is posted, and a mail log where the subject
 * is whatever somebody typed is a log worth nothing. What the browser is
 * trusted with is which message and which client.
 */
export async function fileMessageOnClient(_prev: SendState, formData: FormData): Promise<SendState> {
  const access = await myMailAccess();
  if (!access.ok) return { error: access.message, ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const id = String(formData.get("message_id") ?? "");
  const whole = formData.get("thread") === "yes";
  const mailbox = resolveMailbox(access, String(formData.get("box") ?? ""));
  if (mailbox === false) return { error: "That mailbox is not one you can open here.", ok: null };
  if (!clientId) return { error: "Which client?", ok: null };
  if (!id) return { error: "Which message?", ok: null };

  let message;
  try {
    message = await getMessage(access.token, mailbox, id);
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That message could not be read.", ok: null };
  }

  const mine = (mailbox ?? "").toLowerCase() || access.email.toLowerCase();
  const from = message.from?.address?.toLowerCase() ?? "";
  const incoming = from !== mine;
  const counterpart = incoming ? from : message.to[0]?.address?.toLowerCase() ?? "";

  const filed = await fileOnClient(
    clientId,
    [
      {
        id: message.id,
        conversation: message.conversationId ?? "",
        subject: message.subject,
        sent_at: message.receivedAt,
        direction: incoming ? "Incoming" : "Outgoing",
        counterpart,
        web_link: message.webLink ?? "",
        mailbox: mailbox ?? "",
      },
    ],
    whole ? message.conversationId ?? null : null,
  );
  if (filed.error) return { error: filed.error, ok: null };

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/mail");
  const moved = filed.result?.moved ?? 0;
  return {
    error: null,
    ok: whole && moved > 0 ? `Filed, with ${moved} more from the thread.` : "Filed on the client.",
  };
}

/** Take a filed message off a client, with a reason. The mailbox keeps it. */
export async function unfileMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const id = String(formData.get("mail_id") ?? "");
  const reason = String(formData.get("reason") ?? "").trim();
  const clientId = String(formData.get("client_id") ?? "");
  if (!id) return { error: "Which message?", ok: null };

  const done = await unfileFromClient(id, reason);
  if (done.error) return { error: done.error, ok: null };
  if (clientId) revalidatePath(`/clients/${clientId}`);
  revalidatePath("/mail");
  return { error: null, ok: "Off the client. It is still in the mailbox." };
}

/** Restrict a thread on this client, or let it back out. */
export async function restrictMailThread(_prev: SendState, formData: FormData): Promise<SendState> {
  const conversation = String(formData.get("conversation") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const on = formData.get("restricted") === "yes";
  if (!conversation || !clientId) return { error: "Which thread?", ok: null };

  const done = await setThreadRestricted(conversation, clientId, on);
  if (done.error) return { error: done.error, ok: null };
  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: on ? "Restricted." : "No longer restricted." };
}

/**
 * Keep an attachment from a filed message on the client's record.
 *
 * The bytes come from Microsoft and go into the client's documents under the
 * same rule as a scan somebody uploads: a category, a date, and one copy per
 * client. Nothing about the message itself is kept beyond what filing keeps.
 */
export async function keepAttachment(_prev: SendState, formData: FormData): Promise<SendState> {
  const access = await myMailAccess();
  if (!access.ok) return { error: access.message, ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const id = String(formData.get("message_id") ?? "");
  const attachmentId = String(formData.get("attachment_id") ?? "");
  const category = String(formData.get("category") ?? "Other");
  const restricted = formData.get("restricted") === "on";
  const mailbox = resolveMailbox(access, String(formData.get("box") ?? ""));
  if (mailbox === false) return { error: "That mailbox is not one you can open here.", ok: null };
  if (!clientId || !id || !attachmentId) return { error: "Which attachment?", ok: null };

  // What it is called comes from the list; the bytes come from the file
  // itself, which Graph serves raw and says nothing else about.
  let name = "";
  let mime = "";
  let data: Buffer;
  try {
    const listed = await listAttachments(access.token, mailbox, id);
    const found = listed.find((a) => a.id === attachmentId);
    if (!found) return { error: "That attachment is not on the message any more.", ok: null };
    name = found.name;
    mime = found.contentType;
    const response = await fetchAttachment(access.token, mailbox, id, attachmentId);
    if (!response.ok) throw new Error(`Microsoft did not send the file (${response.status}).`);
    data = Buffer.from(await response.arrayBuffer());
  } catch (err) {
    return { error: err instanceof Error ? err.message : "That attachment could not be read.", ok: null };
  }

  const kept = await keepAttachmentOnClient({
    clientId,
    filename: name,
    mime,
    data,
    category,
    restricted,
    note: "From an email filed on this client",
  });
  if (kept.error) return { error: kept.error, ok: null };
  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: kept.ok };
}
