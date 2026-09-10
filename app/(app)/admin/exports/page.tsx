import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { exportsFor } from "@/lib/exports";
import { money, today, CAN_EDIT_BILLING } from "@/lib/constants";

/**
 * The monthly export.
 *
 * Month end, in one place: pick a month, take the six files, send them to
 * whoever asked. Everything is a plain CSV — the accountant opens it, the CPA
 * opens it, and nothing needs this application to read it, which is the point
 * of an export.
 */

function lastMonths(count: number): string[] {
  const now = new Date();
  const out: string[] = [];
  for (let i = 0; i < count; i++) {
    out.push(new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1)).toISOString().slice(0, 7));
  }
  return out;
}

export default async function ExportsPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string }>;
}) {
  const me = await requireStaff();
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");

  const { month: rawMonth } = await searchParams;
  const months = lastMonths(15);
  const month = /^\d{4}-\d{2}$/.test(rawMonth ?? "") ? rawMonth! : months[0];
  const start = `${month}-01`;
  const [y, m] = month.split("-").map(Number);
  const end = new Date(Date.UTC(y, m, 0)).toISOString().slice(0, 10);

  const supabase = await createClient();

  // Enough of a count that somebody can tell an empty month from a broken
  // link before they email the file to their accountant.
  const [entriesResult, invoicesResult, paidResult, placementsResult, sessionsResult] =
    await Promise.all([
      supabase
        .from("service_entries")
        .select("hours", { count: "exact" })
        .gte("date", start)
        .lte("date", end),
      supabase
        .from("invoices")
        .select("amount", { count: "exact" })
        .gte("date", start)
        .lte("date", end),
      supabase
        .from("invoices")
        .select("amount")
        .eq("status", "Paid")
        .gte("paid_date", start)
        .lte("paid_date", end),
      supabase
        .from("placements")
        .select("client_id", { count: "exact" })
        .gte("start_date", start)
        .lte("start_date", end),
      supabase
        .from("work_session_values")
        .select("hours")
        .gte("worked_on", start)
        .lte("worked_on", end),
    ]);

  const hours = (entriesResult.data ?? []).reduce((t, e) => t + Number(e.hours), 0);
  const invoiced = (invoicesResult.data ?? []).reduce((t, i) => t + Number(i.amount), 0);
  const received = (paidResult.data ?? []).reduce((t, i) => t + Number(i.amount), 0);
  const contractorHours = (sessionsResult.data ?? []).reduce((t, s) => t + Number(s.hours), 0);

  const kinds = exportsFor(me.role);
  const link = (kind: string) => `/api/export/${kind}?month=${month}`;

  return (
    <>
      <h1 className="h1">Monthly export</h1>
      <p className="sub">
        The month as files — for the accountant, the CPA at year end, and anything the screens do
        not answer
      </p>

      <div className="card" style={{ margin: "14px 0" }}>
        <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-end" }}>
          <div className="field" style={{ marginBottom: 0, maxWidth: 220 }}>
            Month
            <form>
              <select name="month" defaultValue={month}>
                {months.map((m) => (
                  <option key={m} value={m}>
                    {m}
                  </option>
                ))}
              </select>
              <button className="btn ghost" type="submit" style={{ marginTop: 6, width: "100%" }}>
                Show {month === months[0] ? "another month" : "this month"}
              </button>
            </form>
          </div>
          <p className="lock" style={{ margin: 0 }}>
            {start} to {end}
          </p>
        </div>
      </div>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", marginBottom: 18 }}
      >
        <div className="card">
          <div className="stat">
            {hours || <span style={{ color: "var(--muted)" }}>0</span>}
            <small>service hours logged</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {money(invoiced)}
            <small>invoiced</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {money(received)}
            <small>received</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {(placementsResult.count ?? 0).toString()}
            <small>placements started</small>
          </div>
        </div>
        {me.role === "Admin" && (
          <div className="card">
            <div className="stat">
              {contractorHours.toFixed(2)}
              <small>contractor hours</small>
            </div>
          </div>
        )}
      </div>

      <div className="card" style={{ padding: 0 }}>
        <table className="t">
          <tbody>
            {kinds.map((k) => (
              <tr key={k.key}>
                <td>
                  <b>{k.label}</b>
                  <div className="lock">{k.detail}</div>
                </td>
                <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                  <a className="btn ghost" href={link(k.key)} style={{ textDecoration: "none" }}>
                    Download CSV
                  </a>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        Each file is read through your own account, so it contains exactly what you can see on the
        screens — no more. Nothing restricted is exported at all: no dates of birth, no addresses,
        no tax numbers, whoever asks. Prepared {today()}.{" "}
        {me.role === "Admin" && <Link href="/admin/contractors">Contractor statements</Link>}
      </p>
    </>
  );
}
