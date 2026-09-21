import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { can, type Access } from "@/lib/roles";
import { STAGES, today } from "@/lib/constants";

/**
 * The caseload in four numbers: every client, the active ones, the new ones
 * this month, and the active ones by stage (owner, 21 Sept 2026).
 *
 * Whose caseload follows the person asking:
 *
 *   Admin, or anyone given Insights - the whole practice.
 *   Job Search, and Intake & Client Reports - the clients assigned to them,
 *     the same caseload "My clients today" works from.
 *   Billing - the clients with an open authorization, which is what they
 *     bill against; they carry no caseload of their own.
 *
 * Every number is also a link to the Clients list showing exactly those
 * clients, built from the list's own filters, so a count and the list it
 * opens are the same question asked twice.
 */
export type Caseload = {
  scope: "practice" | "mine" | "billable";
  scopeLabel: string;
  total: number;
  active: number;
  newThisMonth: number;
  byStage: { stage: string; count: number; href: string }[];
  hrefs: { total: string; active: string; newThisMonth: string };
};

type Me = Access & { id: string };

export async function loadCaseload(supabase: SupabaseClient<Database>, me: Me): Promise<Caseload> {
  const scope: Caseload["scope"] =
    me.role === "Admin" || can(me, "insights") ? "practice" : me.role === "Billing" ? "billable" : "mine";

  let q = supabase.from("clients").select("id, status, stage, created_at, assigned_staff_id");
  if (scope === "mine") q = q.eq("assigned_staff_id", me.id);
  const [{ data: clients }, open] = await Promise.all([
    q,
    scope === "billable"
      ? supabase.from("authorizations").select("client_id").eq("status", "Open")
      : Promise.resolve({ data: null }),
  ]);

  let rows = clients ?? [];
  if (scope === "billable") {
    const withOpen = new Set((open.data ?? []).map((a) => a.client_id));
    rows = rows.filter((c) => withOpen.has(c.id));
  }

  const monthStart = `${today().slice(0, 7)}-01`;
  const active = rows.filter((c) => c.status === "Active");

  // The list's own filters, so each link opens what its number counted.
  const base = new URLSearchParams();
  if (scope === "mine") base.set("assignedStaffId", me.id);
  if (scope === "billable") base.set("openAuth", "true");
  const href = (extra: Record<string, string>) => {
    const p = new URLSearchParams(base);
    for (const [k, v] of Object.entries(extra)) p.set(k, v);
    const s = p.toString();
    return s ? `/clients?${s}` : "/clients";
  };

  return {
    scope,
    scopeLabel:
      scope === "practice" ? "The whole caseload" : scope === "mine" ? "Your caseload" : "Clients with an open authorization",
    total: rows.length,
    active: active.length,
    newThisMonth: rows.filter((c) => c.created_at >= monthStart).length,
    byStage: STAGES.filter((s) => s !== "Closed").map((stage) => ({
      stage,
      count: active.filter((c) => c.stage === stage).length,
      href: href({ status: "Active", stage }),
    })),
    hrefs: {
      total: href({}),
      active: href({ status: "Active" }),
      newThisMonth: href({ since: monthStart, sort: "createdAt", dir: "desc" }),
    },
  };
}
