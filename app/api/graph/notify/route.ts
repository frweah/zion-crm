import { after, NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { sweepAccess } from "@/lib/sync-callers";
import { syncStaffMember } from "@/lib/sync";

/**
 * Microsoft saying a mailbox has changed (0241).
 *
 * Public, like the other webhooks, and so it proves everything rather than
 * trusting anything:
 *
 *   **The handshake.** Microsoft creates a subscription only after posting a
 *   `validationToken` here and getting it back, as plain text, within ten
 *   seconds. That is the first thing this does and it does nothing else
 *   first.
 *
 *   **The secret.** Every real notification carries the `clientState` the
 *   subscription was made with. A notification whose state does not match the
 *   row is not about that mailbox and is dropped - and dropped quietly, with
 *   a 202, because telling an unknown caller which of its guesses was wrong
 *   is a favour to whoever is guessing.
 *
 *   **The payload.** Nothing in the body is believed except which
 *   subscription it is. The notification does not say what arrived and is not
 *   asked to: the CRM syncs that mailbox and finds out for itself, which is
 *   the only shape that keeps "nothing is stored unless somebody files it"
 *   true. A payload carrying the message would be a body arriving uninvited.
 *
 * The sync runs after the response. Microsoft wants a 2xx within seconds and
 * treats a slow endpoint as a failing one, dropping the subscription after
 * enough of them - so the answer goes back first and the work happens behind
 * it. If the process is killed before that finishes, the fifteen-minute sweep
 * picks the mail up, which is the whole reason the sweep is still there.
 */
export const dynamic = "force-dynamic";

type Notification = {
  subscriptionId?: string;
  clientState?: string;
  resource?: string;
  changeType?: string;
};

export async function POST(request: NextRequest) {
  // ── the handshake ───────────────────────────────────────────
  const validation = request.nextUrl.searchParams.get("validationToken");
  if (validation) {
    return new NextResponse(validation, {
      status: 200,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }

  let payload: { value?: Notification[] };
  try {
    payload = (await request.json()) as { value?: Notification[] };
  } catch {
    return NextResponse.json({ ok: false }, { status: 400 });
  }

  const notifications = payload.value ?? [];
  if (notifications.length === 0) return NextResponse.json({ ok: true });

  const admin = createAdminClient();

  // Which of these are genuine, and whose mailbox each one is. One query for
  // the lot: a notification batch is about one subscription in practice, but
  // Microsoft is entitled to batch them.
  const ids = [...new Set(notifications.map((n) => n.subscriptionId).filter(Boolean))] as string[];
  const { data: rows } = await admin
    .from("microsoft_subscriptions")
    .select("staff_id, mailbox_address, subscription_id, client_state, notifications")
    .in("subscription_id", ids);

  const genuine = new Map<string, { staff_id: string; mailbox_address: string; notifications: number }>();
  for (const n of notifications) {
    const row = (rows ?? []).find((r) => r.subscription_id === n.subscriptionId);
    if (!row) continue;
    if (!n.clientState || n.clientState !== row.client_state) continue;
    genuine.set(row.subscription_id, {
      staff_id: row.staff_id,
      mailbox_address: row.mailbox_address,
      notifications: row.notifications ?? 0,
    });
  }

  if (genuine.size === 0) return NextResponse.json({ ok: true }, { status: 202 });

  after(async () => {
    for (const [subscriptionId, who] of genuine) {
      try {
        await admin
          .from("microsoft_subscriptions")
          .update({ last_notified_at: new Date().toISOString(), notifications: who.notifications + 1, last_error: "" })
          .eq("subscription_id", subscriptionId);

        // A person's own mailbox is swept the way the cron sweeps it. A
        // shared mailbox is not handled here: the sweep owns those, and a
        // second path into the same rows is a second place for the watermark
        // to go wrong.
        if (who.mailbox_address !== "") continue;

        const { tokens, writeMail } = sweepAccess(admin, who.staff_id);
        await syncStaffMember(admin, who.staff_id, tokens, writeMail);
      } catch (err) {
        await admin
          .from("microsoft_subscriptions")
          .update({ last_error: (err instanceof Error ? err.message : "The sync failed.").slice(0, 500) })
          .eq("subscription_id", subscriptionId);
      }
    }
  });

  return NextResponse.json({ ok: true }, { status: 202 });
}
