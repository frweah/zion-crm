"use server";

import { revalidatePath } from "next/cache";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff, type CurrentStaff } from "@/lib/session";
import { sendEmail } from "@/lib/email";
import { sendClientSms } from "@/lib/sms";
import { invitationEmail, invitationText } from "@/lib/portal/deliver";

export type PortalAdminState = { error: string | null; ok: string | null };

const text = (formData: FormData, key: string): string | null => {
  const value = String(formData.get(key) ?? "").trim();
  return value || null;
};

const portalUrl = () => `${(process.env.NEXT_PUBLIC_SITE_URL ?? "").replace(/\/$/, "")}/portal`;

/**
 * Telling somebody they have portal access. The owner's rule, in order:
 *
 *   an email address on the portal account, so email it;
 *   otherwise a text, but only where texting consent already exists for that
 *   exact number - a portal invitation is not an excuse to text somebody who
 *   never agreed to be texted, and consent follows the number, not the person;
 *   otherwise nothing is sent, and the staff member tells them in person.
 *
 * The text goes through lib/sms.ts, so it is written into the client's message
 * history first and the database's consent check has the last word. Whichever
 * happens, including nothing, is recorded in the portal's own history.
 */
async function tellThem(
  supabase: SupabaseClient<Database>,
  me: CurrentStaff,
  accountId: string,
  clientId: string,
): Promise<{ sent: boolean; detail: string; sentence: string }> {
  const [{ data: account }, { data: client }, { data: consent }] = await Promise.all([
    supabase.from("portal_accounts").select("name, kind, phone, email").eq("id", accountId).maybeSingle(),
    supabase.from("clients").select("name, ghl_id").eq("id", clientId).maybeSingle(),
    supabase.from("client_sms_consent").select("can_text, consented_phone").eq("client_id", clientId).maybeSingle(),
  ]);

  if (!account || !client) {
    return {
      sent: false,
      detail: "the account could not be read straight after it was made",
      sentence: "Nothing was sent: tell them how to sign in yourself.",
    };
  }

  const where = portalUrl();

  if (account.email) {
    const sent = await sendEmail({
      to: account.email,
      subject: "Your Zion client portal",
      text: invitationEmail({
        name: account.name,
        forClient: account.kind === "Guardian" ? client.name : null,
        where,
      }),
    });
    if (sent.ok) {
      return {
        sent: true,
        detail: `by email to ${account.email}`,
        sentence: `An invitation has gone by email to ${account.email}.`,
      };
    }
    return {
      sent: false,
      detail: `email to ${account.email} failed: ${sent.error}`,
      sentence: `The invitation email did not go out (${sent.error}). Tell them how to sign in, or try again.`,
    };
  }

  const mayText = Boolean(consent?.can_text) && Boolean(account.phone) && consent?.consented_phone === account.phone;
  if (!mayText) {
    return {
      sent: false,
      detail: account.phone
        ? "no email address, and no texting consent for that number"
        : "no email address and no phone number",
      sentence:
        "Nothing was sent, because there is no email address and no texting consent for that number. " +
        "Tell them in person: the portal address, and that they sign in with the number on the account.",
    };
  }

  const sent = await sendClientSms(supabase, {
    clientId,
    clientName: client.name,
    phone: account.phone!,
    body: invitationText({ where }),
    kind: "System",
    staffId: me.id,
    ghlId: client.ghl_id,
  });
  if (sent.ok) {
    return {
      sent: true,
      detail: `by text to ${account.phone}`,
      sentence: `An invitation has gone by text to ${account.phone}.`,
    };
  }
  return {
    sent: false,
    detail: `text to ${account.phone} failed: ${sent.error}`,
    sentence: `The invitation text did not go out (${sent.error}). Tell them how to sign in, or try again.`,
  };
}

/** Records what happened, so the client's file says whether they were told. */
async function noteIt(
  supabase: SupabaseClient<Database>,
  accountId: string,
  result: { sent: boolean; detail: string },
): Promise<void> {
  const { error } = await supabase.rpc("portal_note_invitation", {
    p_account: accountId,
    p_sent: result.sent,
    p_detail: result.detail,
  });
  if (error) console.error(`[portal] an invitation could not be recorded: ${error.message}`);
}

/**
 * Giving, and taking away, a client's portal access. Who may do it, and what a
 * guardian needs, is decided by the database (portal_invite and friends, 0087);
 * these pass the form along, tell the person, and say what happened.
 */
export async function givePortalAccess(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const kind = formData.get("kind") === "Guardian" ? "Guardian" : "Client";

  const supabase = await createClient();
  const { data: accountId, error } = await supabase.rpc("portal_invite", {
    p_client: clientId,
    p_kind: kind,
    p_name: kind === "Guardian" ? text(formData, "name") : null,
    p_relationship: text(formData, "relationship") ?? "",
    p_phone: text(formData, "phone"),
    p_email: text(formData, "email"),
    p_attachment: kind === "Guardian" ? text(formData, "attachment_id") : null,
  });
  if (error) return { error: error.message, ok: null };

  const told = await tellThem(supabase, me, accountId as string, clientId);
  await noteIt(supabase, accountId as string, told);

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: `Portal access given. ${told.sentence}` };
}

export async function sendInvitation(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const accountId = String(formData.get("account_id") ?? "");

  const supabase = await createClient();
  const told = await tellThem(supabase, me, accountId, clientId);
  await noteIt(supabase, accountId, told);

  revalidatePath(`/clients/${clientId}`);
  return told.sent ? { error: null, ok: told.sentence } : { error: told.sentence, ok: null };
}

export async function turnOffPortalAccess(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const supabase = await createClient();
  const { error } = await supabase.rpc("portal_disable_account", {
    p_account: String(formData.get("account_id") ?? ""),
    p_reason: String(formData.get("reason") ?? ""),
  });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Portal access turned off, and every session for it ended." };
}

export async function signOutOfPortal(_prev: PortalAdminState, formData: FormData): Promise<PortalAdminState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("portal_sign_out_everywhere", { p_client: clientId });
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${clientId}`);
  const n = Number(data ?? 0);
  return {
    error: null,
    ok: n === 0 ? "Nobody was signed in to the portal." : `Signed out of ${n} portal ${n === 1 ? "session" : "sessions"}.`,
  };
}
