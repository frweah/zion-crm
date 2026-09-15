import "server-only";
import { sendEmail } from "@/lib/email";
import { findContactByPhone, upsertContact, sendSms } from "@/lib/ghl";
import { ORG } from "@/lib/roles";

export type Delivery = { ok: true } | { ok: false; error: string };

/**
 * A sign-in code, by text through GoHighLevel or by email through Resend.
 *
 * Not through lib/sms.ts. That path writes an sms_messages row first and the
 * database refuses it without texting consent - right for reminders, wrong
 * here: the person has just typed this number into the portal and asked for
 * this one message. Whether it went is recorded against the attempt in
 * portal_login_codes, and the code never appears in a history staff read.
 */
export async function deliverCode(params: {
  channel: "Text" | "Email";
  destination: string;
  name: string;
  code: string;
}): Promise<Delivery> {
  const words =
    `${params.code} is your Zion Voc Rehab portal sign-in code. It works for 10 minutes. ` +
    `Zion staff will never ask you for it.`;

  if (params.channel === "Email") {
    const sent = await sendEmail({
      to: params.destination,
      subject: "Your Zion client portal sign-in code",
      text:
        `${words}\n\nIf you did not ask to sign in, you can ignore this email.\n` +
        `Questions? Call ${ORG.clientPhone}.\n\n${ORG.name}`,
    });
    return sent.ok ? { ok: true } : { ok: false, error: sent.error };
  }

  const found = await findContactByPhone(params.destination);
  if (!found.ok) return { ok: false, error: found.error };
  let contactId = found.data;
  if (!contactId) {
    const made = await upsertContact({ phone: params.destination, name: params.name });
    if (!made.ok) return { ok: false, error: made.error };
    contactId = made.data;
  }
  const sent = await sendSms({ contactId, message: words });
  return sent.ok ? { ok: true } : { ok: false, error: sent.error };
}
