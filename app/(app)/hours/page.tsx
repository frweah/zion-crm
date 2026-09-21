import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today, fmtStamp } from "@/lib/constants";
import {
  LogSessionForm,
  SessionList,
  SubmitStatement,
  ApprovalActions,
  type ApprovalStatement,
  type SessionRow,
  CategoryBreakdown,
  type CategoryOption,
} from "./hours-forms";
import { Expenses, type ExpenseCategory, type ExpenseRow } from "./expenses";
import { WorkTimer, HoursSummary } from "./work-timer";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";

/**
 * Hours, and - for Admin - statement approvals.
 *
 * Approvals has its own entry in the sidebar now, so this screen no longer
 * draws a "My hours / Approvals" strip of its own under the sidebar's. The
 * address is unchanged: ?tab=approvals still opens the approvals view, and
 * only for Admin.
 */
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

    const rows: ApprovalStatement[] = statements.map((s) => ({
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
    }));

    return (
      <>
        <PageHead
          title="Statement approvals"
          context="Contractors' statements for each period, priced by the totals view, waiting on your decision."
        />
        {waiting.length === 0 && (
          <p className="empty">Nothing waiting for approval.</p>
        )}
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="statements"
            columns={[
              { key: "who", label: "Who" },
              { key: "hours", label: "Hours", align: "right" },
              { key: "amount", label: "Comes to", align: "right" },
              { key: "status", label: "Status" },
              { key: "decide", label: "", sortable: false },
            ]}
            rows={rows.map((s) => ({
              key: s.id,
              cells: {
                who: (
                  <>
                    <b>{s.staff_name}</b>
                    <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
                      {s.period_start} to {s.period_end}
                    </div>
                  </>
                ),
                hours: (
                  <>
                    {s.total_hours} hrs
                    {s.unpriced_hours > 0 && (
                      <div className="lock">{s.unpriced_hours} on days with no rate</div>
                    )}
                  </>
                ),
                amount: (
                  <>
                    {s.rate_unit === null && s.total_amount === 0 ? (
                      <span className="lock">no rate on file</span>
                    ) : (
                      <b>{s.total_amount.toLocaleString("en-US", { style: "currency", currency: "USD" })}</b>
                    )}
                    {s.rate_unit === "Flat" && <div className="lock">flat for the period</div>}
                    {s.adjustment !== 0 && (
                      <div className="lock">
                        includes {s.adjustment > 0 ? "+" : ""}
                        {s.adjustment.toFixed(2)} — {s.adjustment_note}
                      </div>
                    )}
                  </>
                ),
                status: (
                  <>
                    <span
                      className={
                        "chip " + (s.status === "Approved" ? "ok" : s.status === "Submitted" ? "warn" : "")
                      }
                    >
                      {s.status}
                    </span>
                    {s.submitted_at && (
                      <div style={{ fontSize: "var(--text-xs)", color: "var(--muted)" }}>{fmtStamp(s.submitted_at)}</div>
                    )}
                  </>
                ),
                decide: <ApprovalActions statement={{ id: s.id, status: s.status }} />,
              },
              sort: {
                who: s.staff_name,
                hours: s.total_hours,
                amount: s.total_amount,
                status: s.status,
              },
              text: `${s.staff_name} ${s.period_start} ${s.period_end} ${s.status}`,
            }))}
            empty="No statements have been submitted yet."
          />
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
    expenseResult,
    expenseCategoryResult,
    currentRateResult,
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
    supabase
      .from("expense_values")
      .select("*")
      .eq("staff_id", me.id)
      .gte("incurred_on", periodStart)
      .lte("incurred_on", periodEnd)
      .order("incurred_on", { ascending: false }),
    supabase
      .from("expense_categories")
      .select("key, label, detail, is_mileage, needs_receipt")
      .eq("active", true)
      .order("sort_order"),
    // The rate itself is set in Admin → System; this is only the one in force.
    supabase.rpc("mileage_rate_on", { p_date: today() }),
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
      <PageHead
        title="Hours"
        context={
          isContractor
            ? "Your work sessions and statements. No clock and no schedule — this is a record of work performed, and the basis of your invoice."
            : "Your logged work and statements."
        }
      />

      {/* Moving between periods is a choice of which period to look at, so it is segmented. */}
      <div className="segmented no-print" style={{ marginBottom: 12 }}>
        <Link href={`/hours?period=${shift(-1)}`}>← Previous period</Link>
        <Link href="/hours" className={periodStart <= today() && today() <= periodEnd ? "on" : undefined}>
          This period
        </Link>
        {periodEnd < today() && <Link href={`/hours?period=${shift(15)}`}>Next period →</Link>}
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

      <Expenses
        rows={(expenseResult.data ?? []) as unknown as ExpenseRow[]}
        categories={(expenseCategoryResult.data ?? []) as ExpenseCategory[]}
        clients={clients}
        today={today()}
        locked={locked}
        currentRate={
          currentRateResult.data === null ? null : Number(currentRateResult.data)
        }
      />

      <CategoryBreakdown sessions={sessions} categories={categories} />

      <SessionList sessions={sessions} locked={locked} categories={categories} />
    </>
  );
}
