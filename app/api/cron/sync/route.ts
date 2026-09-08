import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { syncStaffMember, syncSharedMailbox } from "@/lib/sync";
import { sweepAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";

export const maxDuration = 300;

/**
 * The nightly sweep.
 *
 * Runs for every active staff member who has connected a mailbox, one at a
 * time. One person's failure is recorded against that person and does not stop
 * the others: a expired token belonging to somebody on leave should not mean
 * nobody's mail is logged.
 *
 * Guarded by the same shared secret as the notifications cron, and listed in
 * the middleware's public paths for the same reason — it arrives without a
 * session because there is nobody signed in at three in the morning.
 */
export async function GET(request: NextRequest) {
  const secret = process.env.CRON_SECRET;
  const provided =
    request.headers.get("authorization")?.replace(/^Bearer\s+/i, "") ??
    request.nextUrl.searchParams.get("secret");

  if (!secret || provided !== secret) {
    return NextResponse.json({ error: "Not authorised." }, { status: 401 });
  }

  const admin = createAdminClient();

  const { data: connections, error } = await admin
    .from("microsoft_connections")
    .select("staff_id, microsoft_email, staff!inner(active)")
    .eq("staff.active", true);

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }

  const summary: Record<string, unknown>[] = [];

  for (const connection of connections ?? []) {
    const staffId = connection.staff_id;
    try {
      const { tokens, writeMail } = sweepAccess(admin, staffId);
      const result = await syncStaffMember(admin, staffId, tokens, writeMail);
      summary.push({
        staff_id: staffId,
        mail_logged: result.mailLogged,
        events_pulled: result.eventsPulled,
        skipped_no_match: result.skippedNoMatch,
        errors: result.errors,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "unknown error";
      // Recorded against the person rather than only in a log, so a connection
      // that has quietly stopped working shows up on their own screen.
      await admin
        .from("microsoft_sync_state")
        .upsert(
          { staff_id: staffId, last_run_at: new Date().toISOString(), last_error: message.slice(0, 500) },
          { onConflict: "staff_id" },
        );
      summary.push({ staff_id: staffId, error: message });
    }
  }

  // ── shared mailboxes ───────────────────────────────────────
  // Read with the token of whoever connected each one, because
  // Mail.Read.Shared is delegated: the sweep reaches exactly as far as
  // Exchange has let that person reach.
  const { data: shared } = await admin
    .from("shared_mailboxes")
    .select("address, connected_by, last_mail_sync_at")
    .eq("active", true);

  for (const mailbox of shared ?? []) {
    if (!mailbox.connected_by) {
      await admin
        .from("shared_mailboxes")
        .update({ last_error: "Nobody is connected to read this mailbox." })
        .eq("address", mailbox.address);
      continue;
    }
    try {
      const { tokens } = sweepAccess(admin, mailbox.connected_by);
      const bundle = await tokens.read();
      if (!bundle) throw new Error("The person who connected this mailbox is no longer connected.");
      const token = await ensureFreshToken(bundle, tokens.write);

      const result = await syncSharedMailbox(admin, mailbox, token, async (row) => {
        const { data, error } = await admin.rpc("log_shared_mail_message", {
          p_mailbox: row.mailbox,
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
      });

      summary.push({
        mailbox: mailbox.address,
        mail_logged: result.mailLogged,
        skipped_no_match: result.skippedNoMatch,
        errors: result.errors,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : "unknown error";
      await admin
        .from("shared_mailboxes")
        .update({ last_run_at: new Date().toISOString(), last_error: message.slice(0, 500) })
        .eq("address", mailbox.address);
      summary.push({ mailbox: mailbox.address, error: message });
    }
  }

  return NextResponse.json({ ran: summary.length, results: summary });
}
