import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { syncStaffMember } from "@/lib/sync";
import { sweepAccess } from "@/lib/sync-callers";

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

  return NextResponse.json({ ran: summary.length, results: summary });
}
