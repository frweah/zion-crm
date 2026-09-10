import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { refreshNotifications, getAlerts } from "@/lib/alerts";
import { ROLE_LABEL } from "@/lib/roles";
import { money, today, arBuckets, STAGES, CAN_LOG_HOURS } from "@/lib/constants";
import { DashboardTask } from "./dashboard-task";
import { MicrosoftCard } from "./microsoft-card";
import { WorkTimer, HoursSummary } from "../hours/work-timer";
import { NEEDS, countNeeds } from "@/lib/needs";
import { SharedMailboxCard, type SharedMailboxRow } from "./shared-mailbox-card";

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ microsoft?: string; detail?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();

  // Recalculate before reading, so what is shown is true now rather than as of
  // last night's cron run.
  await refreshNotifications();

  const [
    alerts,
    clientsResult,
    tasksResult,
    authsResult,
    entriesResult,
    invoicesResult,
    categoriesResult,
  ] = await Promise.all([
    getAlerts(),
    supabase.from("clients").select("id, name, stage, status"),
    supabase
      .from("tasks")
      .select("id, title, due, client_id, assigned_staff_id")
      .eq("status", "Open"),
    supabase.from("authorizations").select("id, total_hours, carried_used").eq("status", "Open"),
    supabase.from("service_entries").select("auth_id, hours, non_billable"),
    supabase.from("invoices").select("date, amount, status"),
    supabase
      .from("work_categories")
      .select("key, label")
      .eq("active", true)
      .order("sort_order"),
  ]);

  const workCategories = categoriesResult.data ?? [];

  // Their own outstanding onboarding. The view already limits this to the
  // person asking, so no filter here is doing the security.
  const { data: myChecklist } = await supabase
    .from("staff_checklist")
    .select("label, detail, auto_key, auto_done, done_on, required, phase")
    .eq("phase", "Onboarding")
    .eq("required", true)
    .order("sort_order");

  const { data: msConnection } = await supabase
    .from("microsoft_connections")
    .select("microsoft_email, display_name, connected_at, last_error")
    .eq("staff_id", me.id)
    .maybeSingle();

  const { data: msState } = await supabase
    .from("microsoft_sync_state")
    .select("last_run_at, mail_logged, events_pulled, last_error")
    .eq("staff_id", me.id)
    .maybeSingle();

  const { data: sharedMailboxes } =
    me.role === "Admin"
      ? await supabase
          .from("shared_mailboxes")
          .select("address, label, last_run_at, last_mail_sync_at, mail_logged, last_error")
          .order("address")
      : { data: [] };

  // The timer is on both screens on purpose: Hours is where somebody goes to
  // log time, and the dashboard is where they already are when they start.
  const [{ data: runningTimer }, { data: hoursSummary }] = await Promise.all([
    supabase.from("work_session_timers").select("started_at").maybeSingle(),
    supabase
      .from("my_hours_summary")
      .select("today_hours, period_hours, period_start, period_end")
      .maybeSingle(),
  ]);

  // The five things that might need somebody today. Counted by the same
  // function that lists them on /needs, so a counter cannot disagree with
  // what it opens.
  const needs = await countNeeds(supabase, me);

  const msParams = await searchParams;

  const outstanding = (myChecklist ?? []).filter(
    (r) => !(r.auto_key ? r.auto_done === true : r.done_on !== null),
  );

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

      {CAN_LOG_HOURS.includes(me.role) && (
        <HoursSummary
          todayHours={Number(hoursSummary?.today_hours ?? 0)}
          periodHours={Number(hoursSummary?.period_hours ?? 0)}
          periodStart={hoursSummary?.period_start ?? today()}
          periodEnd={hoursSummary?.period_end ?? today()}
        />
      )}

      {CAN_LOG_HOURS.includes(me.role) && (
        <WorkTimer
          running={runningTimer ?? null}
          clients={activeClients.map((c) => ({ id: c.id, name: c.name }))}
          categories={workCategories}
          today={today()}
        />
      )}

      <MicrosoftCard
        connection={msConnection}
        notice={msParams.microsoft ?? null}
        detail={msParams.detail ?? null}
        lastRun={msState?.last_run_at ?? null}
        lastResult={
          msState
            ? {
                mail_logged: msState.mail_logged,
                events_pulled: msState.events_pulled,
                last_error: msState.last_error,
              }
            : null
        }
      />

      {me.role === "Admin" && (
        <SharedMailboxCard mailboxes={(sharedMailboxes ?? []) as SharedMailboxRow[]} />
      )}

      {outstanding.length > 0 && (
        <div className="card" style={{ marginBottom: 18 }}>
          <h3>Still to do before you are fully set up</h3>
          <ul style={{ margin: "8px 0 0", paddingLeft: 18 }}>
            {outstanding.map((r) => (
              <li key={r.label} style={{ fontSize: 13, marginBottom: 4 }}>
                {r.label}
                {r.detail && <div className="lock">{r.detail}</div>}
              </li>
            ))}
          </ul>
        </div>
      )}

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
        {NEEDS.map((n) => (
          <Link
            key={n.key}
            href={`/dashboard/needs?list=${n.key}`}
            className="card"
            style={{ textDecoration: "none", color: "inherit" }}
          >
            <div className="stat" style={needs[n.key] > 0 ? { color: "var(--bad)" } : undefined}>
              {needs[n.key]}
              <small>{n.label.toLowerCase()}</small>
            </div>
          </Link>
        ))}
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
