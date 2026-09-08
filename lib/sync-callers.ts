import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import type { TokenAccess, MailWriter } from "@/lib/sync";

/**
 * The two ways to reach somebody's mailbox.
 *
 * They are here together on purpose. The difference between them is the whole
 * security boundary of Group C, and it is easier to keep right when both
 * halves are visible at once than when each is buried next to its caller.
 *
 * The signed-in path can only ever reach the caller's own mailbox: the
 * database functions take the staff id from the session and there is no
 * argument to pass. The unattended path can reach anybody's, and is granted to
 * the service role alone, so nothing a person can sign in as will reach it.
 */

/** For a person syncing their own mailbox from the dashboard. */
export function ownAccess(
  supabase: SupabaseClient<Database>,
  staffId: string,
): { tokens: TokenAccess; writeMail: MailWriter } {
  return {
    tokens: {
      read: async () => {
        const { data } = await supabase.rpc("get_microsoft_tokens", { p_staff_id: staffId });
        const row = (data as unknown as
          | { access_token: string | null; refresh_token: string | null; expires_at: string | null }[]
          | null)?.[0];
        if (!row) return null;
        return {
          accessToken: row.access_token ?? "",
          refreshToken: row.refresh_token,
          expiresAt: row.expires_at ? new Date(row.expires_at) : null,
        };
      },
      write: async (t) => {
        // refresh_microsoft_tokens, not set_microsoft_tokens: the latter writes
        // the whole row and would forget whose mailbox this is.
        await supabase.rpc("refresh_microsoft_tokens", {
          p_access: t.accessToken,
          p_refresh: t.refreshToken,
          p_expires_at: t.expiresAt.toISOString(),
        });
      },
    },
    writeMail: async (row) => {
      const { data, error } = await supabase.rpc("log_mail_message", {
        p_client_id: row.clientId,
        p_counselor_id: row.counselorId,
        p_message_id: row.messageId,
        p_conversation_id: row.conversationId,
        p_subject: row.subject,
        p_sent_at: row.sentAt,
        p_direction: row.direction,
        p_counterpart: row.counterpart,
        p_web_link: row.webLink,
      });
      return { logged: data === true, error: error?.message };
    },
  };
}

/** For the nightly sweep, which has no session. */
export function sweepAccess(
  admin: SupabaseClient<Database>,
  staffId: string,
): { tokens: TokenAccess; writeMail: MailWriter } {
  return {
    tokens: {
      read: async () => {
        const { data } = await admin.rpc("get_microsoft_tokens_for_sync", { p_staff_id: staffId });
        const row = (data as unknown as
          | { access_token: string | null; refresh_token: string | null; expires_at: string | null }[]
          | null)?.[0];
        if (!row) return null;
        return {
          accessToken: row.access_token ?? "",
          refreshToken: row.refresh_token,
          expiresAt: row.expires_at ? new Date(row.expires_at) : null,
        };
      },
      write: async (t) => {
        await admin.rpc("set_microsoft_tokens_for_sync", {
          p_staff_id: staffId,
          p_access: t.accessToken,
          p_refresh: t.refreshToken,
          p_expires_at: t.expiresAt.toISOString(),
        });
      },
    },
    writeMail: async (row) => {
      const { data, error } = await admin.rpc("log_mail_message_for_sync", {
        p_staff_id: staffId,
        p_client_id: row.clientId,
        p_counselor_id: row.counselorId,
        p_message_id: row.messageId,
        p_conversation_id: row.conversationId,
        p_subject: row.subject,
        p_sent_at: row.sentAt,
        p_direction: row.direction,
        p_counterpart: row.counterpart,
        p_web_link: row.webLink,
      });
      return { logged: data === true, error: error?.message };
    },
  };
}
