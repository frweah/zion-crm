import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import {
  RetentionView,
  type Policy,
  type Row,
  type Hold,
  type Disposition,
} from "./retention-view";

/**
 * How long records are kept.
 *
 * Admin only — not because the schedule is secret (a counselor asked how long
 * a client's file is kept should be able to find out) but because everything
 * on this screen is an act: confirming a period, holding a record, writing
 * down that something was destroyed.
 */
export default async function RetentionPage() {
  const me = await requireStaff();
  if (me.role !== "Admin") redirect("/dashboard");

  const supabase = await createClient();

  const [policies, rows, holds, dispositions] = await Promise.all([
    supabase
      .from("retention_policies")
      .select("key, label, what, keep_years, clock_starts, authority, confirmed, confirmed_at")
      .eq("active", true)
      .order("sort_order"),
    supabase
      .from("client_retention")
      .select(
        "client_id, name, closed_on, keep_until, policy_confirmed, on_hold, hold_id, hold_reason, due, disposed_at, disposed_action",
      )
      .order("closed_on", { ascending: true }),
    supabase
      .from("legal_holds")
      .select("id, client_id, reason, placed_by_name, placed_at")
      .is("lifted_at", null)
      .order("placed_at", { ascending: false }),
    supabase
      .from("retention_dispositions")
      .select("id, client_name, action, reason, decided_by_name, disposed_at")
      .order("disposed_at", { ascending: false })
      .limit(200),
  ]);

  const all = (rows.data ?? []) as Row[];
  const unconfirmed = (policies.data ?? []).filter((p) => !p.confirmed).length;

  return (
    <>
      <h1 className="h1">Retention</h1>
      <p className="sub">
        {all.length} closed record{all.length === 1 ? "" : "s"} ·{" "}
        {all.filter((r) => r.due).length} past its period ·{" "}
        {(holds.data ?? []).length} under legal hold
        {unconfirmed > 0 && ` · ${unconfirmed} period${unconfirmed === 1 ? "" : "s"} unconfirmed`}
      </p>

      <RetentionView
        policies={(policies.data ?? []) as Policy[]}
        rows={all}
        holds={(holds.data ?? []) as Hold[]}
        dispositions={(dispositions.data ?? []) as Disposition[]}
      />
    </>
  );
}
