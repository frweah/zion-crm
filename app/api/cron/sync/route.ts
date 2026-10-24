import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { syncStaffMember, syncSharedMailbox, type TokenAccess } from "@/lib/sync";
import { sweepAccess } from "@/lib/sync-callers";
import { randomUUID } from "node:crypto";
import { ensureFreshToken } from "@/lib/graph";
import { notifyUrl, renew, subscribe } from "@/lib/mail-subscriptions";
import { pushPendingEvents } from "@/lib/calendar-push";

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
/**
 * Both verbs, like every other cron route.
 *
 * This one exported GET alone, and the scheduler posts: `net.http_post` from
 * pg_cron's `zion-outlook-sync`. So the job reported "succeeded" every day -
 * which only means the SQL that queued the request ran - while the request
 * itself came back **405 Method Not Allowed**, and no mailbox was swept by
 * the scheduler once. Every sweep that has happened was somebody pressing
 * Sync, or the change-notification webhook (owner, 24 Oct 2026).
 *
 * The seven other cron routes all export both. This was the odd one out, and
 * scripts/check-agent-routes.mjs now holds the convention so the next route
 * cannot be.
 */
export async function POST(request: NextRequest) {
  return handle(request);
}

export async function GET(request: NextRequest) {
  return handle(request);
}

async function handle(request: NextRequest) {
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
      // Queued reminders first, so an interview added while Outlook was
      // unreachable reaches the calendar before the pull looks at it.
      const sent = await pushPendingEvents(admin, staffId, tokens);
      const result = await syncStaffMember(admin, staffId, tokens, writeMail);
      // And make sure Microsoft will tell us before the next run (0241). The
      // sweep is what keeps the subscription alive, and the subscription is
      // what makes mail arrive in a minute rather than fifteen. Neither is
      // load-bearing for the other: a subscription that cannot be made is
      // recorded and the sweep carries on.
      const watch = await keepWatching(admin, staffId, tokens);
      summary.push({
        staff_id: staffId,
        events_pushed: sent.pushed,
        events_removed: sent.removed,
        mail_logged: result.mailLogged,
        events_pulled: result.eventsPulled,
        skipped_no_match: result.skippedNoMatch,
        subscription: watch,
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
          p_filed_how: row.filedHow ?? null,
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

/**
 * Make sure Microsoft will tell us about this mailbox (0241).
 *
 * Called once per person per sweep, which is every fifteen minutes - so the
 * cheap case has to be cheap: a live subscription with hours left is left
 * alone and costs one row read. Anything inside its last six hours is
 * renewed, and anything missing or already gone is made again.
 *
 * Nothing here is allowed to stop the sweep. A subscription cannot be created
 * from a machine Microsoft cannot reach, cannot be created before the route
 * is deployed, and stops working the moment somebody disconnects Outlook -
 * none of which is a reason for a person's mail not to be swept. The failure
 * is written on the row and the sweep moves on.
 */
async function keepWatching(
  admin: ReturnType<typeof createAdminClient>,
  staffId: string,
  tokens: TokenAccess,
): Promise<string> {
  if (!notifyUrl()) return "no public address";

  const { data: existing } = await admin
    .from("microsoft_subscriptions")
    .select("subscription_id, client_state, expires_at")
    .eq("staff_id", staffId)
    .eq("mailbox_address", "")
    .maybeSingle();

  /**
   * How much life a subscription needs before it is left alone.
   *
   * Two days, where it was six hours (owner, 24 Oct 2026). The sweep is the
   * only thing that renews these, and six hours of grace meant six hours of
   * outage - a bad deploy, a refused token, a scheduler stopped - between a
   * working mailbox and a dead one.
   *
   * Two days is also what makes the alarm beside it mean anything.
   * supabase/verify_mail_subscriptions.sql fails when a subscription is
   * inside twenty-four hours of expiry, and with a six-hour window every
   * healthy subscription spent eighteen hours a day in that state. Renewing
   * at two days out means a subscription is never legitimately inside one
   * day, so being inside one day is a fault and can be reported as one.
   *
   * It costs one PATCH about every twenty-two hours per mailbox. Microsoft's
   * ceiling on a delegated mail subscription is around seventy hours, so
   * there is no arrangement of these numbers where renewing is late.
   */
  const RENEW_WITHIN_MS = 48 * 3600 * 1000;

  const live =
    existing?.subscription_id &&
    existing.expires_at &&
    new Date(existing.expires_at).getTime() - Date.now() > RENEW_WITHIN_MS;
  if (live) return "live";

  try {
    const bundle = await tokens.read();
    if (!bundle) return "not connected";
    const token = await ensureFreshToken(bundle, tokens.write);

    // A state that outlives the subscription it belongs to, so renewing does
    // not invalidate notifications already in flight.
    const clientState = existing?.client_state || randomUUID();

    let made;
    if (existing?.subscription_id) {
      try {
        made = await renew(token, existing.subscription_id);
      } catch {
        // Microsoft has dropped it, or it was never there. Making a new one
        // is the same act from here.
        made = await subscribe(token, "", clientState);
      }
    } else {
      made = await subscribe(token, "", clientState);
    }

    await admin.from("microsoft_subscriptions").upsert(
      {
        staff_id: staffId,
        mailbox_address: "",
        subscription_id: made.id,
        client_state: clientState,
        expires_at: made.expiresAt,
        renewed_at: new Date().toISOString(),
        last_error: "",
      },
      { onConflict: "staff_id,mailbox_address" },
    );
    return existing?.subscription_id === made.id ? "renewed" : "subscribed";
  } catch (err) {
    const message = err instanceof Error ? err.message : "The subscription failed.";
    await admin.from("microsoft_subscriptions").upsert(
      {
        staff_id: staffId,
        mailbox_address: "",
        subscription_id: existing?.subscription_id ?? "",
        client_state: existing?.client_state || randomUUID(),
        expires_at: existing?.expires_at ?? null,
        last_error: message.slice(0, 500),
      },
      { onConflict: "staff_id,mailbox_address" },
    );
    return "not subscribed";
  }
}
