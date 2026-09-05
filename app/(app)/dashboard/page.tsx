import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { refreshNotifications, getAlerts } from "@/lib/alerts";
import { ROLE_LABEL } from "@/lib/roles";
import { money, today, arBuckets, STAGES } from "@/lib/constants";
import { DashboardTask } from "./dashboard-task";

export default async function DashboardPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  // Recalculate before reading, so what is shown is true now rather than as of
  // last night's cron run.
  await refreshNotifications();

  const [alerts, clientsResult, tasksResult, authsResult, entriesResult, invoicesResult] =
    await Promise.all([
      getAlerts(),
      supabase.from("clients").select("id, stage, status"),
      supabase
        .from("tasks")
        .select("id, title, due, client_id, assigned_staff_id")
        .eq("status", "Open"),
      supabase.from("authorizations").select("id, total_hours, carried_used").eq("status", "Open"),
      supabase.from("service_entries").select("auth_id, hours, non_billable"),
      supabase.from("invoices").select("date, amount, status"),
    ]);

  const clients = clientsResult.data ?? [];
  const auths = authsResult.data ?? [];
  const entries = entriesResult.data ?? [];
  const invoices = (invoicesResult.data ?? []).map((i) => ({ ...i, amount: Number(i.amount) }));

  const isAdmin = me.role === "Admin";
  const myTasks = (tasksResult.data ?? [])
    .filter((t) => isAdmin || t.assigned_staff_id === me.id)
    .sort((a, b) => (a.due ?? "9999").localeCompare(b.due ?? "9999"));

  const activeClients = clients.filter((c) => c.status === "Active");

  const used = new Map<string, number>();
  for (const a of auths) used.set(a.id, Number(a.carried_used ?? 0));
  for (const e of entries) {
    if (e.non_billable) continue;
    if (!used.has(e.auth_id)) continue;
    used.set(e.auth_id, (used.get(e.auth_id) ?? 0) + Number(e.hours));
  }
  const openHours = auths
    .filter((a) => a.total_hours != null)
    .reduce((acc, a) => acc + Math.max(0, Number(a.total_hours) - (used.get(a.id) ?? 0)), 0);

  const ar = arBuckets(invoices);

  const byStage = STAGES.map((s) => ({
    stage: s,
    n: activeClients.filter((c) => c.stage === s).length,
  })).filter((x) => x.n > 0);

  const seesBilling = me.role === "Admin" || me.role === "Billing";
  const seesAr = seesBilling || me.role === "Reports";

  return (
    <>
      <h1 className="h1">Today</h1>
      <p className="sub">
        {ROLE_LABEL[me.role]} view · {me.name}
      </p>

      {alerts.length > 0 ? (
        <div style={{ marginBottom: 18 }}>
          {alerts.map((a) => (
            <div key={a.id} className={"alert " + (a.level === "bad" ? "bad" : "")}>
              {a.href ? (
                <Link href={a.href} style={{ color: "inherit" }}>
                  {a.text}
                </Link>
              ) : (
                a.text
              )}
            </div>
          ))}
        </div>
      ) : (
        <div className="alert ok" style={{ marginBottom: 18 }}>
          Nothing needs attention: no authorization is short of hours or expiring, no invoice is
          overdue, no task is past its date, and no counselor follow-up is due.
        </div>
      )}

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(175px, 1fr))", marginBottom: 16 }}
      >
        <div className="card">
          <div className="stat">
            {activeClients.length}
            <small>active clients</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {myTasks.length}
            <small>open tasks{isAdmin ? " (all staff)" : ""}</small>
          </div>
        </div>
        {seesBilling && (
          <div className="card">
            <div className="stat">
              {openHours}
              <small>authorized hours remaining</small>
            </div>
          </div>
        )}
        {seesAr && (
          <div className="card">
            <div className="stat">
              {money(ar.total)}
              <small>outstanding A/R</small>
            </div>
          </div>
        )}
      </div>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))" }}>
        <div className="card">
          <h3>Tasks due</h3>
          {myTasks.length === 0 && (
            <div className="empty">
              Nothing due. Add a task from{" "}
              <Link href="/tasks" style={{ color: "var(--teal)" }}>
                Tasks
              </Link>
              .
            </div>
          )}
          {myTasks.slice(0, 8).map((t) => (
            <DashboardTask
              key={t.id}
              id={t.id}
              title={t.title}
              due={t.due}
              clientId={t.client_id}
              overdue={Boolean(t.due && t.due < today())}
            />
          ))}
          {myTasks.length > 8 && (
            <p className="sub" style={{ margin: "10px 0 0" }}>
              <Link href="/tasks" style={{ color: "var(--teal)" }}>
                {myTasks.length - 8} more
              </Link>
            </p>
          )}
        </div>

        <div className="card">
          <h3>Pipeline</h3>
          {byStage.length === 0 && <div className="empty">No active clients yet.</div>}
          {byStage.map((x) => (
            <div key={x.stage} style={{ fontSize: 13, margin: "6px 0" }}>
              <div className="row2" style={{ justifyContent: "space-between" }}>
                <span>{x.stage}</span>
                <b>{x.n}</b>
              </div>
              <div className="bar">
                <i style={{ width: `${(x.n / Math.max(1, activeClients.length)) * 100}%` }} />
              </div>
            </div>
          ))}
          <Link
            href="/clients"
            className="btn ghost"
            style={{ marginTop: 12, display: "inline-block", textDecoration: "none" }}
          >
            Open clients
          </Link>
        </div>
      </div>
    </>
  );
}
