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
} from "./hours-forms";

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
      supabase.from("work_sessions").select("statement_id, hours, voided"),
    ]);

    const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));
    const hoursByStatement = new Map<string, number>();
    for (const s of sessionsResult.data ?? []) {
      if (s.voided || !s.statement_id) continue;
      hoursByStatement.set(
        s.statement_id,
        (hoursByStatement.get(s.statement_id) ?? 0) + Number(s.hours),
      );
    }

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
                <th>Status</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {statements.length === 0 && (
                <tr>
                  <td colSpan={4} className="empty">
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
                    total_hours: hoursByStatement.get(s.id) ?? 0,
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
  const [sessionsResult, statementResult, clientsResult, staffResult] = await Promise.all([
    supabase
      .from("work_sessions")
      .select(
        "id, worked_on, hours, description, client_id, voided, corrects_id, correction_reason, statement_id, created_at, created_by",
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
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase.from("staff").select("id, name"),
  ]);

  const clients = clientsResult.data ?? [];
  const clientName = new Map(clients.map((c) => [c.id, c.name]));
  const staffName = new Map((staffResult.data ?? []).map((s) => [s.id, s.name]));

  const sessions: SessionRow[] = (sessionsResult.data ?? []).map((s) => ({
    id: s.id,
    worked_on: s.worked_on,
    hours: Number(s.hours),
    description: s.description,
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

      <SubmitStatement
        periodStart={periodStart}
        periodEnd={periodEnd}
        totalHours={totalHours}
        status={statement?.status ?? null}
        returnNote={statement?.return_note ?? ""}
      />

      {!locked && <LogSessionForm clients={clients} />}

      <SessionList sessions={sessions} locked={locked} />
    </>
  );
}
