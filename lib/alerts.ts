import "server-only";
import { after } from "next/server";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * What needs attention.
 *
 * The rules themselves live in the database — public.generate_notifications()
 * in migration 0011 — and run nightly under pg_cron, so an authorization that
 * runs out of hours on a Friday is waiting on Monday morning rather than being
 * noticed on Monday afternoon.
 *
 * This module used to compute the same rules in TypeScript. It no longer does.
 * Two implementations of "what needs attention" would eventually disagree, and
 * the one nobody was reading would be the one that was wrong.
 */
export type Alert = {
  id: string;
  level: "bad" | "warn";
  text: string;
  href: string | null;
  createdAt: string;
};

/**
 * Works the alerts out now. No screen calls this on the way to a page any more
 * (owner, 18 Sept 2026): see refreshAlertsIfStale.
 */
export async function refreshNotifications(): Promise<void> {
  const supabase = await createClient();
  await supabase.rpc("generate_notifications");
}

/**
 * Open notifications for the signed-in staff member.
 *
 * No role filter here: the RLS policy on notifications already limits rows to
 * the reader's role, so a Job Search member cannot see Billing's A/R chasing
 * even by asking for it.
 */
export async function getAlerts(): Promise<Alert[]> {
  const supabase = await createClient();

  const { data } = await supabase
    .from("notifications")
    .select("id, level, text, href, created_at")
    .is("resolved_at", null)
    .order("level")
    .order("created_at", { ascending: false })
    .limit(50);

  return (data ?? []).map((n) => ({
    id: n.id,
    level: n.level === "bad" ? "bad" : "warn",
    text: n.text,
    href: n.href,
    createdAt: n.created_at,
  }));
}

/** How old the alerts may be before a dashboard asks for them to be worked out again. */
export const ALERTS_STALE_AFTER_MS = 60 * 60 * 1000;

/**
 * The owner's rule (18 Sept 2026): the dashboard reads the alerts as they are,
 * worked out nightly. If they were last worked out more than an hour ago, they
 * are worked out again after the page has been sent - never on the way to it.
 * The next page load shows the result.
 *
 * The run happens as the service role because the request that asked for it
 * has finished by then; generate_notifications() works out everybody's alerts
 * and nobody's in particular, exactly as the nightly job does, and records the
 * run in job_runs (0093). Two dashboards opening at once can both start one;
 * the alerts are keyed, so the second changes nothing.
 *
 * Returns whether a refresh was started.
 */
export function refreshAlertsIfStale(lastRunAt: string | null | undefined): boolean {
  if (lastRunAt && Date.now() - Date.parse(lastRunAt) < ALERTS_STALE_AFTER_MS) return false;
  after(async () => {
    const { error } = await createAdminClient().rpc("generate_notifications");
    if (error) console.error(`[alerts] background refresh failed: ${error.message}`);
  });
  return true;
}
