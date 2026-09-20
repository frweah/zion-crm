"use server";

import { redirect } from "next/navigation";
import { myMailAccess, resolveMailbox } from "@/lib/mail-access";
import { getMessage } from "@/lib/mail";
import { sendNew, replyOwn, forwardOwn, moveToDeletedItems } from "@/lib/mail-send";

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
 * Delete (owner, 19 Sept 2026): moves a message to Deleted Items, as
 * Outlook's Delete does - it can be got back there, and a message already
 * logged on a record stays logged.
 *
 * The person's own mailbox, or the shared one if they work it and their
 * connection carries the permission for it (owner, 19 Sept 2026: Billing
 * clears service@ here rather than switching to Outlook). A message in the
 * shared mailbox goes to that mailbox's Deleted Items, not to theirs.
 */
export async function deleteMessage(_prev: SendState, formData: FormData): Promise<SendState> {
  const access = await myMailAccess();
  if (!access.ok) return { error: access.message, ok: null };
  const mailbox = resolveMailbox(access, String(formData.get("box") ?? ""));
  if (mailbox === false) return { error: "That mailbox is not yours to delete from.", ok: null };
  if (mailbox === null && !access.canDelete) {
    return { error: "Deleting is not turned on for your Outlook yet. Use “Turn sending on” on the Mail screen.", ok: null };
  }
  if (mailbox !== null && !access.canDeleteShared) {
    return {
      error:
        "Deleting from the shared mailbox is not turned on for your Outlook yet. Use “Turn sending on” on the Mail screen and reconnect once.",
      ok: null,
    };
  }
  const id = String(formData.get("message_id") ?? "");
  if (!id) return { error: "Which message?", ok: null };

  try {
    await moveToDeletedItems(access.token, id, mailbox);
  } catch (err) {
    return { error: err instanceof Error ? err.message : "It was not deleted.", ok: null };
  }
  const back = String(formData.get("back") ?? "/mail");
  redirect(back.startsWith("/mail") ? back : "/mail");
}
