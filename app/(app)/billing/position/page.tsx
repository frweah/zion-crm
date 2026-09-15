import { redirect } from "next/navigation";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, CAN_EDIT_BILLING } from "@/lib/constants";

/**
 * Paid & outstanding.
 *
 * Per client, and for the practice: what USOR authorized, what was invoiced,
 * what was paid, and what is still owed. "Paid" is payments on record - the
 * workbook's, those reconciled from warrants, and invoices marked paid by hand -
 * not a guess from invoice statuses.
 *
 *   Outstanding       invoiced and not yet paid
 *   Not yet invoiced  authorized and not yet asked for
 */

type Position = {
  auth_id: string;
  client_id: string;
  client_name: string;
  auth_number: string | null;
  service_type: string | null;
  status: string | null;
  authorized: number | null;
  invoiced: number | null;
  paid: number | null;
  outstanding: number | null;
  not_yet_invoiced: number | null;
  last_paid_on: string | null;
  payments: number | null;
};

type Totals = { authorized: number; invoiced: number; paid: number; outstanding: number; notYet: number };

const add = (t: Totals, p: Position): Totals => ({
  authorized: t.authorized + Number(p.authorized ?? 0),
  invoiced: t.invoiced + Number(p.invoiced ?? 0),
  paid: t.paid + Number(p.paid ?? 0),
  outstanding: t.outstanding + Number(p.outstanding ?? 0),
  notYet: t.notYet + Number(p.not_yet_invoiced ?? 0),
});
const ZERO: Totals = { authorized: 0, invoiced: 0, paid: 0, outstanding: 0, notYet: 0 };

export default async function PositionPage({ searchParams }: { searchParams: Promise<{ show?: string }> }) {
  const me = await requireStaff();
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");
  const { show } = await searchParams;
  const owedOnly = show === "outstanding";

  const supabase = await createClient();
  const { data } = await supabase.from("billing_position").select("*").order("client_name").order("auth_number");
  const rows = (data ?? []) as unknown as Position[];

  const overall = rows.reduce(add, ZERO);

  const clients = new Map<string, { name: string; rows: Position[]; totals: Totals; lastPaid: string | null }>();
  for (const r of rows) {
    const c = clients.get(r.client_id) ?? { name: r.client_name, rows: [], totals: ZERO, lastPaid: null };
    c.rows.push(r);
    c.totals = add(c.totals, r);
    if (r.last_paid_on && (!c.lastPaid || r.last_paid_on > c.lastPaid)) c.lastPaid = r.last_paid_on;
    clients.set(r.client_id, c);
  }
  const list = [...clients.entries()]
    .filter(([, c]) => !owedOnly || c.totals.outstanding > 0)
    .sort((a, b) => b[1].totals.outstanding - a[1].totals.outstanding || a[1].name.localeCompare(b[1].name));

  const tile = (value: number, label: string, tone?: "bad") => (
    <div className="card">
      <div className="stat" style={tone && value > 0 ? { color: "var(--bad)" } : undefined}>
        {money(value)}
        <small>{label}</small>
      </div>
    </div>
  );

  return (
    <>
      <h1 className="h1">Paid &amp; outstanding</h1>
      <p className="sub">
        What USOR authorized, was invoiced for, and has paid - per client and for the practice.
        Payments come from the workbook, the warrants read from the <Link href="/billing/warrants">_Warrants folder</Link>,
        and invoices marked paid by hand.
      </p>

      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(170px, 1fr))", marginBottom: 18 }}>
        {tile(overall.authorized, "authorized")}
        {tile(overall.invoiced, "invoiced")}
        {tile(overall.paid, "paid")}
        {tile(overall.outstanding, "invoiced, not yet paid", "bad")}
        {tile(overall.notYet, "authorized, not yet invoiced")}
      </div>

      <div className="row2" style={{ gap: 8, marginBottom: 10 }}>
        <Link className={"btn " + (owedOnly ? "ghost" : "")} href="/billing/position">
          All clients
        </Link>
        <Link className={"btn " + (owedOnly ? "" : "ghost")} href="/billing/position?show=outstanding">
          Only clients with money outstanding
        </Link>
      </div>

      <div className="card" style={{ padding: 0, overflowX: "auto" }}>
        <table className="t">
          <thead>
            <tr>
              <th>Client</th>
              <th style={{ textAlign: "right" }}>Authorized</th>
              <th style={{ textAlign: "right" }}>Invoiced</th>
              <th style={{ textAlign: "right" }}>Paid</th>
              <th style={{ textAlign: "right" }}>Outstanding</th>
              <th style={{ textAlign: "right" }}>Not yet invoiced</th>
              <th>Last paid</th>
            </tr>
          </thead>
          <tbody>
            {list.map(([id, c]) => (
              <tr key={id} style={{ verticalAlign: "top" }}>
                <td>
                  <details>
                    <summary style={{ cursor: "pointer" }}>
                      <b>{c.name}</b> <span className="lock">· {c.rows.length} authorization{c.rows.length === 1 ? "" : "s"}</span>
                    </summary>
                    <table className="t" style={{ marginTop: 6 }}>
                      <tbody>
                        {c.rows.map((r) => (
                          <tr key={r.auth_id}>
                            <td className="lock">
                              <Link href={`/clients/${id}?tab=billing`}>{r.auth_number || "(no number)"}</Link> · {r.service_type} · {r.status}
                            </td>
                            <td className="lock" style={{ textAlign: "right" }}>{money(Number(r.authorized ?? 0))}</td>
                            <td className="lock" style={{ textAlign: "right" }}>{money(Number(r.invoiced ?? 0))}</td>
                            <td className="lock" style={{ textAlign: "right" }}>{money(Number(r.paid ?? 0))}</td>
                            <td className="lock" style={{ textAlign: "right" }}>{money(Number(r.outstanding ?? 0))}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </details>
                </td>
                <td style={{ textAlign: "right" }}>{money(c.totals.authorized)}</td>
                <td style={{ textAlign: "right" }}>{money(c.totals.invoiced)}</td>
                <td style={{ textAlign: "right" }}>{money(c.totals.paid)}</td>
                <td style={{ textAlign: "right", color: c.totals.outstanding > 0 ? "var(--bad)" : undefined }}>
                  {money(c.totals.outstanding)}
                </td>
                <td style={{ textAlign: "right" }}>{money(c.totals.notYet)}</td>
                <td className="lock">{c.lastPaid ?? "—"}</td>
              </tr>
            ))}
            {list.length === 0 && (
              <tr>
                <td colSpan={7} className="empty">
                  {owedOnly ? "Nothing outstanding." : "No authorizations on file."}
                </td>
              </tr>
            )}
          </tbody>
          {list.length > 0 && (
            <tfoot>
              <tr>
                <td>
                  <b>All clients</b>
                </td>
                <td style={{ textAlign: "right" }}><b>{money(overall.authorized)}</b></td>
                <td style={{ textAlign: "right" }}><b>{money(overall.invoiced)}</b></td>
                <td style={{ textAlign: "right" }}><b>{money(overall.paid)}</b></td>
                <td style={{ textAlign: "right" }}><b>{money(overall.outstanding)}</b></td>
                <td style={{ textAlign: "right" }}><b>{money(overall.notYet)}</b></td>
                <td />
              </tr>
            </tfoot>
          )}
        </table>
      </div>
    </>
  );
}
