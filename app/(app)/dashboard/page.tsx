import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { ROLE_LABEL } from "@/lib/roles";

/**
 * Phase 1 shell. The real dashboard — alerts, KPIs, today's tasks — is Phase 2,
 * ported from the prototype's Dashboard component. What this proves today is
 * that a logged-in staff member reaches the app and that RLS is answering.
 */
export default async function DashboardPage() {
  const staff = await requireStaff();
  const supabase = await createClient();

  const [{ count: clients }, { count: openTasks }, { count: openAuths }] = await Promise.all([
    supabase.from("clients").select("*", { count: "exact", head: true }),
    supabase
      .from("tasks")
      .select("*", { count: "exact", head: true })
      .eq("status", "Open")
      .eq("assigned_staff_id", staff.id),
    supabase
      .from("authorizations")
      .select("*", { count: "exact", head: true })
      .eq("status", "Open"),
  ]);

  return (
    <>
      <h1 className="h1">Dashboard</h1>
      <p className="sub">
        Signed in as {staff.name} · {ROLE_LABEL[staff.role]}
      </p>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))" }}>
        <div className="card">
          <div className="stat">
            {clients ?? 0}
            <small>clients</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {openTasks ?? 0}
            <small>open tasks assigned to you</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {openAuths ?? 0}
            <small>open authorizations</small>
          </div>
        </div>
      </div>

      <div className="card" style={{ marginTop: 14 }}>
        <h3>Phase 1 — foundation</h3>
        <p className="sub" style={{ margin: 0 }}>
          Database, roles, row-level security and the invite flow are in place. The screens come
          next, ported from the prototype: Clients, Tasks, Forms, Counselors, Billing, Reports and
          SOPs. Client records arrive in the migration step, after the screens can display them.
        </p>
      </div>
    </>
  );
}
