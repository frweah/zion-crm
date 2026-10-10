import "server-only";
import { listMessages, listAttachments, fetchAttachment } from "@/lib/mail";
import { replyOwn, sendNew } from "@/lib/mail-send";
import { isFromUtahGov } from "@/lib/intake-source";

/**
 * Reading service@ for the intake, and thanking the counselor.
 *
 * Here rather than in the route for the reason lib/sync.ts exists: a module
 * that holds a mail token does not also hold a database client. It reads, it
 * hands each PDF to a handler, and it does what the handler says about the
 * reply - so the deciding and the recording happen on the other side of a
 * callback, where a mistake cannot be a mail bug writing to a client's record.
 *
 * It is the one place in the system that sends mail without somebody pressing
 * Send, and it can say two things and no others: THANKS, in reply to a
 * document that arrived (Rule 4), and a nudge whose words it is handed
 * (Rule 6). It composes neither - THANKS is a constant and the nudge is built
 * in the database beside the rule that decides a nudge is owed, for the same
 * reason the notifications are. The check in scripts/check-mail.mjs holds this
 * file to exactly that, rather than trusting it with mail in general.
 */
export const THANKS = "Received, thank you.";

export type IntakeMessage = {
  id: string;
  from: string;
  subject: string;
  receivedAt: string;
};

export type IntakePdf = { name: string; size: number; bytes: Uint8Array };

/**
 * What the caller does with what arrives.
 *
 * `pdf` returns whether the counselor should be thanked for this document. It
 * returns rather than sends, because whether a reply is owed is a fact about
 * the record - one per document, a re-send getting the same reply - and the
 * database is what knows it.
 */
export type IntakeHandler = {
  skipped(message: IntakeMessage, decision: "not utah.gov" | "no pdf", detail: string): Promise<void>;
  pdf(message: IntakeMessage, pdf: IntakePdf): Promise<{ reply: boolean }>;
  failed(message: IntakeMessage, pdf: IntakePdf, detail: string): Promise<void>;
};

const isPdf = (a: { name: string; contentType: string }) =>
  /pdf/i.test(a.contentType) || /\.pdf$/i.test(a.name);

export async function readIntakeMailbox(
  token: string,
  mailbox: string | null,
  handler: IntakeHandler,
  limit = 40,
): Promise<{ lookedAt: number; replied: number; pdfs: number }> {
  const messages = await listMessages(token, { mailbox, folder: "inbox", top: limit });
  let replied = 0;
  let pdfs = 0;

  for (const m of messages) {
    const message: IntakeMessage = {
      id: m.id,
      from: m.from?.address ?? "",
      subject: m.subject,
      receivedAt: m.receivedAt,
    };

    // Anything not from Utah is left alone - not read, not recorded against
    // anybody, nobody notified. The handler is told so the skip can be found.
    if (!isFromUtahGov(message.from)) {
      await handler.skipped(message, "not utah.gov", "left alone");
      continue;
    }

    const attachments = m.hasAttachments ? await listAttachments(token, mailbox, m.id) : [];
    const wanted = attachments.filter(isPdf);
    if (wanted.length === 0) {
      await handler.skipped(message, "no pdf", `${attachments.length} attachment(s), none a PDF`);
      continue;
    }

    for (const a of wanted) {
      let bytes: Uint8Array;
      try {
        const response = await fetchAttachment(token, mailbox, m.id, a.id);
        if (!response.ok) throw new Error(`the attachment could not be fetched (${response.status})`);
        bytes = new Uint8Array(await response.arrayBuffer());
      } catch (err) {
        await handler.failed(
          message,
          { name: a.name, size: a.size, bytes: new Uint8Array() },
          err instanceof Error ? err.message : "the attachment could not be fetched",
        );
        continue;
      }

      const pdf: IntakePdf = { name: a.name, size: a.size, bytes };
      pdfs += 1;
      try {
        const { reply } = await handler.pdf(message, pdf);
        if (reply) {
          await replyOwn(token, m.id, THANKS, false);
          replied += 1;
        }
      } catch (err) {
        await handler.failed(message, pdf, err instanceof Error ? err.message : "failed");
      }
    }
  }

  return { lookedAt: messages.length, replied, pdfs };
}

/**
 * The nudge to a counselor about a referral with no authorization (Rule 6).
 *
 * The words arrive already written - `referrals_without_authorization` builds
 * them beside the rule that decides a nudge is owed - so there is one place
 * that says what the practice says. Margaret is copied in, which is the
 * brief's instruction and also what makes an automated email answerable: the
 * reply comes back to a person who knows the case.
 */
export async function sendReferralNudge(
  token: string,
  to: string,
  cc: string[],
  subject: string,
  body: string,
): Promise<void> {
  if (!to.trim()) throw new Error("a nudge with nobody to send it to");
  if (!body.trim()) throw new Error("a nudge with no words in it");
  await sendNew(token, { to: [to], cc, subject, text: body });
}
