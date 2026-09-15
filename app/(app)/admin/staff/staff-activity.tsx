import Link from "next/link";
import { DataTable } from "../../data-table";

export type ActivityRow = {
  staff_id: string;
  staff_name: string;
  role: string;
  employment_type: string;
  active: boolean;
  hours: number;
  sessions: number;
  days_worked: number;
  statements_submitted: number;
  statements_approved: number;
  amount_paid: number;
  clients_assigned: number;
  tasks_open: number;
  tasks_done: number;
  notes_written: number;
  leads_added: number;
};

const usd = (n: number) => Number(n).toLocaleString("en-US", { style: "currency", currency: "USD" });
const num = (n: number) => Number(n).toLocaleString("en-US");

/**
 * What each person did over a period.
 *
 * Hours are counted on the day the work was done and payments on the day they
 * were paid, so the two columns will not agree for the same window and are not
 * meant to. Caseload and open tasks are the position today rather than over the
 * period, because "who is carrying what now" is the question that gets asked.
 *
 * The totals for active staff are a sentence under the table rather than a
 * footer row, so sorting the table never moves them.
 */
export function StaffActivity({
  rows,
  from,
  to,
}: {
  rows: ActivityRow[];
  from: string;
  to: string;
}) {
  const active = rows.filter((r) => r.active);
  const totals = active.reduce(
    (a, r) => ({
      hours: a.hours + Number(r.hours),
      paid: a.paid + Number(r.amount_paid),
      clients: a.clients + Number(r.clients_assigned),
      open: a.open + Number(r.tasks_open),
    }),
    { hours: 0, paid: 0, clients: 0, open: 0 },
  );

  const year = Number(to.slice(0, 4));
  // The period links are a choice of period, so .segmented, with the one in view marked.
  const thisYear = from === `${year}-01-01`;
  const isLastYear = !thisYear && from.endsWith("-01-01") && to === `${from.slice(0, 4)}-12-31`;

  const dash = (n: number, show: (n: number) => string = num) => (Number(n) > 0 ? show(n) : "—");

  return (
    <>
      <h3 style={{ marginTop: 26 }}>Staff report</h3>
      <div className="row2" style={{ alignItems: "center", marginBottom: 10 }}>
        <span className="sub" style={{ margin: 0 }}>
          {from} to {to}
        </span>
        <div className="segmented no-print">
          <Link className={thisYear ? "on" : ""} href={`/admin/people?from=${year}-01-01&to=${to}`}>
            This year
          </Link>
          <Link
            className={isLastYear ? "on" : ""}
            href={`/admin/people?from=${year - 1}-01-01&to=${year - 1}-12-31`}
          >
            Last year
          </Link>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="people"
          columns={[
            { key: "who", label: "Who" },
            { key: "hours", label: "Hours", align: "right" },
            { key: "days", label: "Days", align: "right" },
            { key: "statements", label: "Statements" },
            { key: "paid", label: "Paid", align: "right" },
            { key: "caseload", label: "Caseload", align: "right" },
            { key: "tasks", label: "Tasks" },
            { key: "notes", label: "Notes", align: "right" },
            { key: "leads", label: "Leads", align: "right" },
          ]}
          rows={rows.map((r) => ({
            key: r.staff_id,
            text: `${r.staff_name} ${r.role} ${r.employment_type}${r.active ? "" : " inactive"}`,
            sort: {
              who: r.staff_name,
              hours: Number(r.hours),
              days: Number(r.days_worked),
              statements: Number(r.statements_approved),
              paid: Number(r.amount_paid),
              caseload: Number(r.clients_assigned),
              tasks: Number(r.tasks_open),
              notes: Number(r.notes_written),
              leads: Number(r.leads_added),
            },
            cells: {
              who: (
                <>
                  <b>{r.staff_name}</b>
                  <div className="lock">
                    {r.role} · {r.employment_type}
                    {!r.active && " · inactive"}
                  </div>
                </>
              ),
              hours: dash(r.hours),
              days: dash(r.days_worked),
              statements:
                Number(r.statements_approved) > 0 || Number(r.statements_submitted) > 0 ? (
                  <>
                    {num(r.statements_approved)} approved
                    {Number(r.statements_submitted) > 0 && (
                      <div className="lock">{num(r.statements_submitted)} awaiting</div>
                    )}
                  </>
                ) : (
                  "—"
                ),
              paid: dash(r.amount_paid, usd),
              caseload: dash(r.clients_assigned),
              tasks: (
                <>
                  {Number(r.tasks_open) > 0 ? `${num(r.tasks_open)} open` : "—"}
                  {Number(r.tasks_done) > 0 && <div className="lock">{num(r.tasks_done)} closed</div>}
                </>
              ),
              notes: dash(r.notes_written),
              leads: dash(r.leads_added),
            },
          }))}
          empty="Nobody on the staff list recorded anything in this period."
        />
        <p className="sub" style={{ margin: 0, padding: "12px 14px", borderTop: "1px solid var(--line)" }}>
          <b>Active staff:</b> {num(totals.hours)} hours · {usd(totals.paid)} paid ·{" "}
          {num(totals.clients)} on caseloads · {num(totals.open)} open tasks
        </p>
      </div>

      <p className="lock" style={{ marginTop: 8 }}>
        Hours are counted on the day the work was done; payments on the day they were paid, which
        is the rule a 1099 follows. The two will not agree for the same window, and are not meant
        to. Caseload and open tasks are the position today, not over the period. A dash is nothing
        recorded, which is not the same as a measured zero.
      </p>
    </>
  );
}
