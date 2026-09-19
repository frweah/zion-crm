import { can } from "@/lib/roles";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { refreshAlertsIfStale, getAlerts } from "@/lib/alerts";
import { ROLE_LABEL } from "@/lib/roles";
import { today, CAN_LOG_HOURS } from "@/lib/constants";
import { DashboardTask } from "./dashboard-task";
import { MicrosoftCard } from "./microsoft-card";
import { WorkTimer, HoursSummary } from "../hours/work-timer";
import { NEEDS, loadNeed, countNeeds } from "@/lib/needs";
import { PageHead } from "../page-head";

/**
 * The dashboard: one page.
 *
 * "Today" and "Needs attention" were two tabs; the counters are here now, and
 * each opens its list at /dashboard/needs. Tasks due means one thing on both:
 * open tasks due today or earlier, yours - everybody's for Admin - so the card
 * and the counter can never disagree. Tasks dated later, or with no date, are
 * on Tasks. The pipeline figures are Insights', and the shared mailboxes are
 * a setting in Admin → System.
 */
export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ microsoft?: string; detail?: string }>;
}) {
  const me = await requireStaff();
  const supabase = await createClient();

  // The alerts as they are - worked out nightly, and again in the background
  // when a dashboard finds them more than an hour old (below). Nothing is
  // recalculated on the way to this page.
  const [alerts, runResult, clientsResult, categoriesResult, checklistResult, msConnectionResult, msStateResult, timerResult, summaryResult] =
    await Promise.all([
      getAlerts(),
      supabase.from("job_runs").select("last_run_at").eq("job", "notifications").maybeSingle(),
      supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
      supabase.from("work_categories").select("key, label").eq("active", true).order("sort_order"),
      // Their own outstanding onboarding. The view shows Admin everybody's (the
      // staff screen needs that), so the staff_id filter is what makes this "mine".
      supabase
        .from("staff_checklist")
        .select("task_id, label, detail, auto_key, auto_done, done_on, required, phase")
        .eq("staff_id", me.id)
        .eq("phase", "Onboarding")
        .eq("required", true)
        .order("sort_order"),
      supabase
        .from("microsoft_connections")
        .select("microsoft_email, display_name, connected_at, last_error")
        .eq("staff_id", me.id)
        .maybeSingle(),
      supabase
        .from("microsoft_sync_state")
        .select("last_run_at, mail_logged, events_pulled, last_error")
        .eq("staff_id", me.id)
        .maybeSingle(),
      // The timer is on both screens on purpose: Hours is where somebody goes to
      // log time, and the dashboard is where they already are when they start.
      supabase.from("work_session_timers").select("started_at").maybeSingle(),
      supabase.from("my_hours_summary").select("today_hours, period_hours, period_start, period_end").maybeSingle(),
    ]);

  // The five counters, and the tasks behind the first one - from the same
  // function that lists them, so a counter cannot disagree with what it opens.
  const [needs, tasksDue] = await Promise.all([countNeeds(supabase, me), loadNeed(supabase, "tasks", me)]);
  const taskIds = tasksDue.map((t) => t.id);
  const { data: taskRows } = taskIds.length
    ? await supabase.from("tasks").select("id, title, due, client_id").in("id", taskIds.slice(0, 8))
    : { data: [] as { id: string; title: string; due: string | null; client_id: string | null }[] };
  const taskById = new Map((taskRows ?? []).map((t) => [t.id, t]));

  refreshAlertsIfStale(runResult.data?.last_run_at);

  const msParams = await searchParams;
  const outstanding = (checklistResult.data ?? []).filter(
    (r) => !(r.auto_key ? r.auto_done === true : r.done_on !== null),
  );
  const hoursSummary = summaryResult.data;
  const msState = msStateResult.data;

  return (
    <>
      <PageHead title="Dashboard" context={`${ROLE_LABEL[me.role]} view · ${me.name}`} />

      {(CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit")) && (
        <HoursSummary
          todayHours={Number(hoursSummary?.today_hours ?? 0)}
          periodHours={Number(hoursSummary?.period_hours ?? 0)}
          periodStart={hoursSummary?.period_start ?? today()}
          periodEnd={hoursSummary?.period_end ?? today()}
        />
      )}

      {(CAN_LOG_HOURS.includes(me.role) || can(me, "billing", "edit")) && (
        <WorkTimer
          running={timerResult.data ?? null}
          clients={clientsResult.data ?? []}
          categories={categoriesResult.data ?? []}
          today={today()}
        />
      )}

      <MicrosoftCard
        connection={msConnectionResult.data}
        notice={msParams.microsoft ?? null}
        detail={msParams.detail ?? null}
        lastRun={msState?.last_run_at ?? null}
        lastResult={
          msState
            ? { mail_logged: msState.mail_logged, events_pulled: msState.events_pulled, last_error: msState.last_error }
            : null
        }
      />

      {outstanding.length > 0 && (
        <div className="card" style={{ marginBottom: 18 }}>
          <h3>Still to do before you are fully set up</h3>
          <ul style={{ margin: "8px 0 0", paddingLeft: 18 }}>
            {outstanding.map((r) => (
              <li key={r.task_id} style={{ fontSize: "var(--text-md)", marginBottom: 4 }}>
                {r.label}
                {r.detail && <div className="lock">{r.detail}</div>}
              </li>
            ))}
          </ul>
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

      <div className="card">
        <h3>Tasks due today or earlier</h3>
        {tasksDue.length === 0 && (
          <div className="empty">
            Nothing due. Tasks dated later, or with no date, are on{" "}
            <Link href="/tasks" style={{ color: "var(--teal)" }}>
              Tasks
            </Link>
            .
          </div>
        )}
        {tasksDue.slice(0, 8).map((t) => {
          const row = taskById.get(t.id);
          return (
            <DashboardTask
              key={t.id}
              id={t.id}
              title={row?.title ?? t.title}
              due={row?.due ?? t.when}
              clientId={row?.client_id ?? null}
              overdue={Boolean(t.when && t.when < today())}
            />
          );
        })}
        {tasksDue.length > 8 && (
          <p className="sub" style={{ margin: "10px 0 0" }}>
            <Link href="/dashboard/needs?list=tasks" style={{ color: "var(--teal)" }}>
              {tasksDue.length - 8} more
            </Link>
          </p>
        )}
      </div>
    </>
  );
}
