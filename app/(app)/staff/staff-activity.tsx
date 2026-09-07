import Link from "next/link";

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

  return (
    <div className="card" style={{ marginTop: 24, padding: 0 }}>
      <div style={{ padding: "16px 16px 0" }}>
        <h3>Staff report</h3>
        <p className="sub" style={{ marginTop: 0 }}>
          {from} to {to}.{" "}
          <Link href={`/staff?from=${year}-01-01&to=${to}`}>This year</Link>
          {" · "}
          <Link href={`/staff?from=${year - 1}-01-01&to=${year - 1}-12-31`}>Last year</Link>
        </p>
      </div>

      <table className="t">
        <thead>
          <tr>
            <th>Who</th>
            <th>Hours</th>
            <th>Days</th>
            <th>Statements</th>
            <th>Paid</th>
            <th>Caseload</th>
            <th>Tasks</th>
            <th>Notes</th>
            <th>Leads</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.staff_id} style={r.active ? undefined : { opacity: 0.55 }}>
              <td>
                <b>{r.staff_name}</b>
                <div style={{ fontSize: 12, color: "var(--muted)" }}>
                  {r.role} · {r.employment_type}
                  {!r.active && " · inactive"}
                </div>
              </td>
              <td>{Number(r.hours) > 0 ? num(r.hours) : "—"}</td>
              <td>{Number(r.days_worked) > 0 ? num(r.days_worked) : "—"}</td>
              <td>
                {Number(r.statements_approved) > 0 || Number(r.statements_submitted) > 0 ? (
                  <>
                    {num(r.statements_approved)} approved
                    {Number(r.statements_submitted) > 0 && (
                      <div style={{ fontSize: 12, color: "var(--muted)" }}>
                        {num(r.statements_submitted)} awaiting
                      </div>
                    )}
                  </>
                ) : (
                  "—"
                )}
              </td>
              <td>{Number(r.amount_paid) > 0 ? usd(r.amount_paid) : "—"}</td>
              <td>{Number(r.clients_assigned) > 0 ? num(r.clients_assigned) : "—"}</td>
              <td>
                {Number(r.tasks_open) > 0 ? `${num(r.tasks_open)} open` : "—"}
                {Number(r.tasks_done) > 0 && (
                  <div style={{ fontSize: 12, color: "var(--muted)" }}>
                    {num(r.tasks_done)} closed
                  </div>
                )}
              </td>
              <td>{Number(r.notes_written) > 0 ? num(r.notes_written) : "—"}</td>
              <td>{Number(r.leads_added) > 0 ? num(r.leads_added) : "—"}</td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <td>
              <b>Active staff</b>
            </td>
            <td>
              <b>{num(totals.hours)}</b>
            </td>
            <td />
            <td />
            <td>
              <b>{usd(totals.paid)}</b>
            </td>
            <td>
              <b>{num(totals.clients)}</b>
            </td>
            <td>
              <b>{num(totals.open)} open</b>
            </td>
            <td />
            <td />
          </tr>
        </tfoot>
      </table>

      <p className="lock" style={{ padding: "0 16px 16px" }}>
        Hours are counted on the day the work was done; payments on the day they were paid, which
        is the rule a 1099 follows. The two will not agree for the same window, and are not meant
        to. Caseload and open tasks are the position today, not over the period. A dash is nothing
        recorded, which is not the same as a measured zero.
      </p>
    </div>
  );
}
