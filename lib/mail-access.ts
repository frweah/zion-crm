import "server-only";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff, type CurrentStaff } from "@/lib/session";
import { ownAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { hasScope, MAIL_SEND_SCOPE, MAIL_WRITE_SCOPE, SHARED_MAILBOX_SCOPE, SHARED_WRITE_SCOPE } from "@/lib/microsoft";

/**
 * What the signed-in person can do with Outlook from the CRM (Messaging brief, M).
 *
 * Always their own token, read through the functions that can only return the
 * caller's own (0029), never anybody else's.
 *
 * The shared mailbox: offered to the roles that work it (Admin and Billing),
 * once their connection holds Mail.Read.Shared. Whether they can actually open
 * it is Exchange's decision - a person Exchange has not given access gets a
 * refusal from Microsoft and nothing else. resolveMailbox is the one door:
 * every read of a shared mailbox goes through it.
 */
export const SHARED_MAILBOX_ROLES = ["Admin", "Billing"];

export type MailAccess =
  | { ok: false; reason: "not-signed-in" | "not-connected" | "expired"; me: CurrentStaff | null; message: string }
  | {
      ok: true;
      me: CurrentStaff;
      token: string;
      email: string;
      canSend: boolean;
      /** Can move a message in their own mailbox to Deleted Items. */
      canDelete: boolean;
      /**
       * The same in a shared mailbox they are offered (owner, 19 Sept 2026).
       * Separate from canDelete because it is a separate permission and a
       * separate mailbox: somebody may have one without the other, and the
       * screen should offer exactly what they have.
       */
      canDeleteShared: boolean;
      sharedMailboxes: { address: string; label: string }[];
    };

export async function myMailAccess(): Promise<MailAccess> {
  const me = await getCurrentStaff();
  if (!me) return { ok: false, reason: "not-signed-in", me: null, message: "You are not signed in." };

  const supabase = await createClient();
  const { tokens } = ownAccess(supabase, me.id);
  const [bundle, { data: conn }, { data: shared }] = await Promise.all([
    tokens.read(),
    supabase.from("microsoft_connections").select("microsoft_email, scopes").eq("staff_id", me.id).maybeSingle(),
    SHARED_MAILBOX_ROLES.includes(me.role)
      ? supabase.from("shared_mailboxes").select("address, label").eq("active", true).order("address")
      : Promise.resolve({ data: [] as { address: string; label: string }[] }),
  ]);

  if (!bundle || !conn) {
    return {
      ok: false,
      reason: "not-connected",
      me,
      message: "Your Outlook is not connected. Connect it from the Dashboard, then come back.",
    };
  }

  let token: string;
  try {
    token = await ensureFreshToken(bundle, tokens.write);
  } catch (err) {
    return {
      ok: false,
      reason: "expired",
      me,
      message: err instanceof Error ? err.message : "The Outlook connection needs reconnecting.",
    };
  }

  const scopes = conn.scopes ?? "";
  return {
    ok: true,
    me,
    token,
    email: conn.microsoft_email,
    canSend: hasScope(scopes, MAIL_SEND_SCOPE),
    canDelete: hasScope(scopes, MAIL_WRITE_SCOPE),
    canDeleteShared: SHARED_MAILBOX_ROLES.includes(me.role) && hasScope(scopes, SHARED_WRITE_SCOPE),
    sharedMailboxes:
      SHARED_MAILBOX_ROLES.includes(me.role) && hasScope(scopes, SHARED_MAILBOX_SCOPE) ? (shared ?? []) : [],
  };
}

/**
 * The mailbox a request may read: the person's own (null), or a shared one
 * they are offered. Anything else asked for is refused here, before Microsoft
 * is asked.
 */
export function resolveMailbox(access: Extract<MailAccess, { ok: true }>, requested: string | null | undefined): string | null | false {
  if (!requested || requested === "me") return null;
  const wanted = requested.toLowerCase();
  return access.sharedMailboxes.some((m) => m.address.toLowerCase() === wanted) ? wanted : false;
}
