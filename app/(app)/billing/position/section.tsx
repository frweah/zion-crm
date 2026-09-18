import { redirect } from "next/navigation";
import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money, CAN_EDIT_BILLING } from "@/lib/constants";
import { DataTable, type DataRow } from "../../data-table";
import { readBillingOffices, readBoParam, matchesBo } from "@/lib/billing-offices";
import { BillingOfficeFilter, withBo } from "../../billing-office-filter";

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

export default async function PositionPage({ searchParams }: { searchParams: Promise<{ show?: string; bo?: string }> }) {
  const me = await requireStaff();
  if (!CAN_EDIT_BILLING.includes(me.role)) redirect("/dashboard");
  const { show, bo: rawBo } = await searchParams;
  const owedOnly = show === "outstanding";

  const supabase = await createClient();
  const { data } = await supabase.from("billing_position").select("*").order("client_name").order("auth_number");
  // The billing office the Invoices tab is filtered to, if any - one filter
  // for the invoices and the money they add up to.
  const billing = await readBillingOffices(supabase);
  const bo = readBoParam(rawBo, billing.billingOffices);
  const officeName = (clientId: string) => billing.forClient(clientId)?.name ?? "";
  const rows = ((data ?? []) as unknown as Position[]).filter((r) => matchesBo(bo, billing.forClient(r.client_id)));
  const scope = !bo ? "All clients" : bo === "none" ? "Clients with no billing office" : `${billing.byId.get(bo)?.name ?? "This billing office"}`;

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

  // One row a client. Their authorizations open underneath the name rather
  // than as rows of their own, so the columns always add up to that client.
  const clientRows: DataRow[] = list.map(([id, c]) => ({
    key: id,
    cells: {
      client: (
        <details>
          <summary style={{ cursor: "pointer" }}>
            <b>{c.name}</b>{" "}
            <span className="lock">
              · {c.rows.length} authorization{c.rows.length === 1 ? "" : "s"}
            </span>
          </summary>
          <ul style={{ listStyle: "none", margin: "6px 0 0", padding: 0 }}>
            {c.rows.map((r) => (
              <li key={r.auth_id} className="lock" style={{ padding: "2px 0" }}>
                <Link href={`/clients/${id}?tab=billing`}>{r.auth_number || "(no number)"}</Link> ·{" "}
                {r.service_type} · {r.status} — {money(Number(r.authorized ?? 0))} authorized ·{" "}
                {money(Number(r.invoiced ?? 0))} invoiced · {money(Number(r.paid ?? 0))} paid ·{" "}
                {money(Number(r.outstanding ?? 0))} outstanding
              </li>
            ))}
          </ul>
        </details>
      ),
      billingOffice: officeName(id) || <span className="lock">None</span>,
      authorized: money(c.totals.authorized),
      invoiced: money(c.totals.invoiced),
      paid: money(c.totals.paid),
      outstanding: (
        <span style={c.totals.outstanding > 0 ? { color: "var(--bad)" } : undefined}>
          {money(c.totals.outstanding)}
        </span>
      ),
      notYet: money(c.totals.notYet),
      lastPaid: <span className="lock">{c.lastPaid ?? "—"}</span>,
    },
    sort: {
      client: c.name,
      billingOffice: officeName(id),
      authorized: c.totals.authorized,
      invoiced: c.totals.invoiced,
      paid: c.totals.paid,
      outstanding: c.totals.outstanding,
      notYet: c.totals.notYet,
      lastPaid: c.lastPaid,
    },
    text: [c.name, officeName(id), ...c.rows.map((r) => r.auth_number ?? "")].join(" "),
  }));

  return (
    <>
      <h2 className="h2">Paid &amp; outstanding</h2>
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

      <BillingOfficeFilter
        billingOffices={billing.billingOffices}
        selected={bo}
        href={(b) => withBo(owedOnly ? "/billing?tab=invoices&show=outstanding" : "/billing?tab=invoices", b, "#paid-and-outstanding")}
      />

      {/* Which clients to show is a filter on this list, not a tab. */}
      <div style={{ marginBottom: 10 }}>
        <div className="segmented">
          <Link className={owedOnly ? undefined : "on"} href={withBo("/billing?tab=invoices", bo, "#paid-and-outstanding")}>
            All clients
          </Link>
          <Link className={owedOnly ? "on" : undefined} href={withBo("/billing?tab=invoices&show=outstanding", bo, "#paid-and-outstanding")}>
            Only clients with money outstanding
          </Link>
        </div>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="clients"
          columns={[
            { key: "client", label: "Client" },
            { key: "billingOffice", label: "Billing office" },
            { key: "authorized", label: "Authorized", align: "right" },
            { key: "invoiced", label: "Invoiced", align: "right" },
            { key: "paid", label: "Paid", align: "right" },
            { key: "outstanding", label: "Outstanding", align: "right" },
            { key: "notYet", label: "Not yet invoiced", align: "right" },
            { key: "lastPaid", label: "Last paid" },
          ]}
          rows={clientRows}
          empty={owedOnly ? "Nothing outstanding: no client is owed money." : "No authorizations are on file."}
        />
      </div>

      {/* The practice's totals, which were the table's footer. They count every client, whichever are showing. */}
      {rows.length > 0 && (
        <p className="lock" style={{ margin: "8px 0 0" }}>
          <b>{scope}:</b> {money(overall.authorized)} authorized · {money(overall.invoiced)} invoiced ·{" "}
          {money(overall.paid)} paid · {money(overall.outstanding)} outstanding · {money(overall.notYet)} not yet
          invoiced.
        </p>
      )}
    </>
  );
}
