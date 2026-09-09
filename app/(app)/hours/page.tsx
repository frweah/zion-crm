import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import {
  LogSessionForm,
  SessionList,
  SubmitStatement,
  ApprovalRow,
  type SessionRow,
  CategoryBreakdown,
  type CategoryOption,
} from "./hours-forms";
import { WorkTimer, HoursSummary } from "./work-timer";

export default async function HoursPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; period?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, period } = await searchParams;
  const isAdmin = me.role === "Admin";
  const tab = isAdmin && rawTab === "approvals" ? "approvals" : "mine";

  const supabase = await createClient();

  // The period being viewed: the one containing today unless asked otherwise.
  const anchorDate = /^\d{4}-\d{2}-\d{2}$/.test(period ?? "") ? period! : today();
  const [{ data: startData }, { data: endData }] = await Promise.all([
    supabase.rpc("period_start", { d: anchorDate }),
    supabase.rpc("period_end", { d: anchorDate }),
  ]);
  const periodStart = (startData as unknown as string) ?? anchorDate;
  const periodEnd = (endData as unknown as string) ?? anchorDate;

  const { data: employment } = await supabase
    .from("staff_employment")
    .select("employment_type")
    .eq("staff_id", me.id)
    .maybeSingle();
  const isContractor = (employment?.employment_type ?? "Contractor") === "Contractor";

  const header = (
    <>
      <h1 className="h1">Hours</h1>
      <p className="sub">
        {isContractor
          ? "Your work sessions and statements. No clock and no schedule — this is a record of work performed, and the basis of your invoice."
          : "Your logged work and statements."}
      </p>
      {isAdmin && (
        <nav className="tabs">
          <Link href="/hours" className={tab === "mine" ? "on" : ""}>
            My hours
          </Link>
          <Link href="/hours?tab=approvals" className={tab === "approvals" ? "on" : ""}>
            Approvals
          </Link>
        </nav>
      )}
    </>
  );

  // ── Admin: statements waiting on a decision ──────────────────
  if (tab === "approvals") {
    const [statementsResult, staffResult, sessionsResult] = await Promise.all([
      supabase
        .from("contractor_statements")
        .select("id, staff_id, period_start, period_end, status, submitted_at")
        .order("period_start", { ascending: false }),
      supabase.from("staff").select("id, name"),
      // The totals view prices the work; summing hours here would be a second
      // answer to the same question, and the two would drift.
      supabase
        .from("contractor_statement_totals")
        .select("statement_id, total_hours, total_amount, unpriced_hours, rate_unit, adjustment, adjustment_note"),
    ]);

    const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
    const totals = new Map((sessionsResult.data ?? []).map((t) => [t.statement_id, t]));

    const statements = statementsResult.data ?? [];
    const waiting = statements.filter((s) => s.status === "Submitted");

    return (
      <>
        {header}
        {waiting.length === 0 && (
          <div className="alert ok">Nothing waiting for approval.</div>
        )}
        <div className="card" style={{ padding: 0 }}>
          <table className="t">
            <thead>
              <tr>
                <th>Who</th>
                <th>Hours</th>
                <th>Comes to</th>
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {statements.length === 0 && (
                <tr>
                  <td colSpan={5} className="empty">
                    No statements yet.
                  </td>
                </tr>
              )}
              {statements.map((s) => (
                <ApprovalRow
                  key={s.id}
                  statement={{
                    id: s.id,
                    staff_name: staffName.get(s.staff_id) ?? "—",
                    period_start: s.period_start,
                    period_end: s.period_end,
                    status: s.status,
                    total_hours: Number(totals.get(s.id)?.total_hours ?? 0),
                    total_amount: Number(totals.get(s.id)?.total_amount ?? 0),
                    unpriced_hours: Number(totals.get(s.id)?.unpriced_hours ?? 0),
                    rate_unit: totals.get(s.id)?.rate_unit ?? null,
                    adjustment: Number(totals.get(s.id)?.adjustment ?? 0),
                    adjustment_note: totals.get(s.id)?.adjustment_note ?? "",
                    submitted_at: s.submitted_at,
                  }}
                />
              ))}
            </tbody>
          </table>
        </div>
        <p className="lock" style={{ marginTop: 10 }}>
          Approving settles the hours: nothing can be added to the statement or corrected away
          afterwards. Reopen it if something needs to change.
        </p>
      </>
    );
  }

  // ── Everyone: my own hours for the period ────────────────────
  const [
    sessionsResult,
    statementResult,
    totalsResult,
    clientsResult,
    staffResult,
    timerResult,
    summaryResult,
    rateResult,
    categoriesResult,
  ] = await Promise.all([
    supabase
      .from("work_sessions")
      .select(
        "id, worked_on, hours, description, category, client_id, voided, corrects_id, correction_reason, statement_id, created_at, created_by",
      )
      .eq("staff_id", me.id)
      .gte("worked_on", periodStart)
      .lte("worked_on", periodEnd),
    supabase
      .from("contractor_statements")
      .select("id, status, return_note")
      .eq("staff_id", me.id)
      .eq("period_start", periodStart)
      .maybeSingle(),
    supabase
      .from("contractor_statement_totals")
      .select("total_amount, unpriced_hours, rate_unit, period_rate")
      .eq("staff_id", me.id)
      .eq("period_start", periodStart)
      .maybeSingle(),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase.from("staff").select("id, name"),
    supabase.from("work_session_timers").select("started_at").maybeSingle(),
    supabase
      .from("my_hours_summary")
      .select("today_hours, period_hours, period_start, period_end")
      .maybeSingle(),
    // Their own rate. The function takes a staff id, but it is security
    // invoker over an own-row policy, so passing somebody else's returns
    // nothing — checked in verify_pay before it was put on a screen.
    supabase.rpc("pay_rate_on", { p_staff_id: me.id, p_date: today() }),
    supabase
      .from("work_categories")
      .select("key, label, detail, billable")
      .eq("active", true)
      .order("sort_order"),
  ]);

  const clients = clientsResult.data ?? [];
  const categories = (categoriesResult.data ?? []) as CategoryOption[];
  const categoryLabel = new Map(categories.map((c) => [c.key, c.label]));
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));

  const sessions: SessionRow[] = (sessionsResult.data ?? []).map((s) => ({
    id: s.id,
    worked_on: s.worked_on,
    hours: Number(s.hours),
    description: s.description,
    category: s.category,
    category_label: s.category ? (categoryLabel.get(s.category) ?? s.category) : "",
    client_id: s.client_id,
    client_name: s.client_id ? (clientName.get(s.client_id) ?? "") : "",
    voided: s.voided,
    corrects_id: s.corrects_id,
    correction_reason: s.correction_reason,
    statement_id: s.statement_id,
    created_at: s.created_at,
    created_by_name: s.created_by ? (staffName.get(s.created_by) ?? "") : "",
  }));

  const totalHours = sessions.filter((s) => !s.voided).reduce((t, s) => t + s.hours, 0);
  const statement = statementResult.data;
  const locked = statement?.status === "Approved";

  // No rate on file is not the same as a period worth nothing, so it shows as
  // no figure rather than as zero.
  const totals = totalsResult.data;
  const totalAmount = totals?.period_rate == null ? null : Number(totals.total_amount);

  // Previous and next period, so someone can catch up on a missed week.
  const shift = (days: number) => {
    const d = new Date(periodStart + "T00:00:00");
    d.setDate(d.getDate() + days);
    return d.toISOString().slice(0, 10);
  };

  return (
    <>
      {header}

      <div className="row2" style={{ marginBottom: 12, alignItems: "center" }}>
        <Link className="btn ghost" href={`/hours?period=${shift(-1)}`} style={{ textDecoration: "none" }}>
          ← Previous period
        </Link>
        <Link className="btn ghost" href="/hours" style={{ textDecoration: "none" }}>
          This period
        </Link>
        {periodEnd < today() && (
          <Link className="btn ghost" href={`/hours?period=${shift(15)}`} style={{ textDecoration: "none" }}>
            Next period →
          </Link>
        )}
      </div>

      <HoursSummary
        todayHours={Number(summaryResult.data?.today_hours ?? 0)}
        periodHours={Number(summaryResult.data?.period_hours ?? 0)}
        periodStart={summaryResult.data?.period_start ?? periodStart}
        periodEnd={summaryResult.data?.period_end ?? periodEnd}
        rate={
          (rateResult.data as unknown as { pay_rate: number; rate_unit: string }[] | null)?.[0] ??
          null
        }
      />

      <WorkTimer
        running={timerResult.data ?? null}
        clients={clients}
        categories={categories}
        today={today()}
      />

      <SubmitStatement
        periodStart={periodStart}
        periodEnd={periodEnd}
        totalHours={totalHours}
        totalAmount={totalAmount}
        unpricedHours={Number(totals?.unpriced_hours ?? 0)}
        rateUnit={totals?.rate_unit ?? null}
        status={statement?.status ?? null}
        returnNote={statement?.return_note ?? ""}
      />

      {!locked && <LogSessionForm clients={clients} categories={categories} />}

      <CategoryBreakdown sessions={sessions} categories={categories} />

      <SessionList sessions={sessions} locked={locked} categories={categories} />
    </>
  );
}
