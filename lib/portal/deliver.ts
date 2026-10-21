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

/**
 * What an invitation says, in each form.
 *
 * Whether one is sent at all is the owner's rule, and lives where the account
 * is made (app/(app)/clients/[id]/portal-actions.ts): email where there is an
 * address, a text only where texting consent already exists for that number,
 * and otherwise nobody is messaged and staff tell the person themselves.
 *
 * Neither message carries a link to click. The people using this portal are
 * exactly the people a scam text about "your benefits account" is aimed at, so
 * the invitation names the address to type and nothing else, and both messages
 * say Zion will never ask for the code.
 */
export function invitationEmail(params: { name: string; forClient: string | null; where: string }): string {
  const forWhom = params.forClient ? ` for ${params.forClient}` : "";
  return (
    `Hello ${params.name.trim().split(/\s+/)[0] || params.name},\n\n` +
    `${ORG.name} has set up a client portal account${forWhom}.\n\n` +
    `Go to ${params.where} and enter this email address. We send a 6-digit code each time you sign in, ` +
    `so there is no password to remember. Zion staff will never ask you for that code.\n\n` +
    `The first time, you will be asked to read and agree to the portal terms.\n\n` +
    `If you would rather not use the portal, that is fine - nothing changes about how Zion works with you.\n\n` +
    `Questions? Call ${ORG.clientPhone}.\n\n${ORG.name}\n${ORG.address}`
  );
}

export function invitationText(params: { where: string }): string {
  return (
    `Zion Voc Rehab has set up your client portal. Go to ${params.where} and enter this number to get a ` +
    `6-digit sign-in code. We will never ask you for the code. Questions: ${ORG.clientPhone}.`
  );
}
