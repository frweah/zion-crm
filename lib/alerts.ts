import "server-only";
import { createClient } from "@/lib/supabase/server";

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
 * Recalculates before reading, so the dashboard reflects this moment rather
 * than last night. Cheap — a handful of aggregates over small tables — and it
 * means a task finished this morning stops nagging immediately.
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
