import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { exportsFor } from "@/lib/exports";
import { money, today, CAN_EDIT_BILLING } from "@/lib/constants";
import { DataTable } from "../../data-table";
import { readBillingOffices } from "@/lib/billing-offices";

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
        .select("hours, auth_id", { count: "exact" })
        .gte("date", start)
        .lte("date", end),
      supabase
        .from("invoices")
        .select("amount, auth_id", { count: "exact" })
        .gte("date", start)
        .lte("date", end),
      supabase
        .from("invoices")
        .select("amount, auth_id")
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

  // The month, office by office: the close is done one CRP billing office at a
  // time, so the same figures are split by who pays them. Outstanding is every
  // invoice sent and not yet paid, whenever it was raised - what each office
  // owes at the close, not only what was raised this month.
  const [billing, { data: authRows }, { data: sentRows }] = await Promise.all([
    readBillingOffices(supabase),
    supabase.from("authorizations").select("id, client_id"),
    supabase.from("invoices").select("amount, auth_id").eq("status", "Sent"),
  ]);
  const clientOfAuth = new Map((authRows ?? []).map((a) => [a.id, a.client_id]));
  type Tally = { hours: number; invoiced: number; received: number; outstanding: number; unpaid: number };
  const tally = new Map<string, Tally>();
  const bump = (authId: string | null, field: keyof Tally, value: number) => {
    const key = billing.forClient(authId ? clientOfAuth.get(authId) : null)?.id ?? "none";
    const t = tally.get(key) ?? { hours: 0, invoiced: 0, received: 0, outstanding: 0, unpaid: 0 };
    t[field] += value;
    tally.set(key, t);
  };
  for (const e of entriesResult.data ?? []) bump(e.auth_id, "hours", Number(e.hours));
  for (const i of invoicesResult.data ?? []) bump(i.auth_id, "invoiced", Number(i.amount));
  for (const i of paidResult.data ?? []) bump(i.auth_id, "received", Number(i.amount));
  for (const i of sentRows ?? []) {
    bump(i.auth_id, "outstanding", Number(i.amount));
    bump(i.auth_id, "unpaid", 1);
  }
  const zero: Tally = { hours: 0, invoiced: 0, received: 0, outstanding: 0, unpaid: 0 };
  const officeRows = [
    ...billing.billingOffices.map((b) => ({ key: b.id, name: b.name, reconcile: true })),
    ...(tally.has("none") ? [{ key: "none", name: "No billing office", reconcile: false }] : []),
  ].map((o) => ({ ...o, t: tally.get(o.key) ?? zero }));

  const kinds = exportsFor(me.role);
  const link = (kind: string) => `/api/export/${kind}?month=${month}`;

  return (
    <>
      <h2 className="h2">Monthly export</h2>
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

      <h3 style={{ margin: "0 0 8px" }}>By billing office</h3>
      <div className="card" style={{ padding: 0, marginBottom: 8 }}>
        <DataTable
          label="billing offices"
          columns={[
            { key: "office", label: "Billing office" },
            { key: "hours", label: "Hours logged", align: "right" },
            { key: "invoiced", label: "Invoiced", align: "right" },
            { key: "received", label: "Received", align: "right" },
            { key: "outstanding", label: "Outstanding now", align: "right" },
            { key: "reconcile", label: "", sortable: false },
          ]}
          rows={officeRows.map((o) => ({
            key: o.key,
            text: o.name,
            sort: { office: o.name, hours: o.t.hours, invoiced: o.t.invoiced, received: o.t.received, outstanding: o.t.outstanding },
            cells: {
              office: <b>{o.name}</b>,
              hours: o.t.hours ? o.t.hours.toFixed(2) : "—",
              invoiced: money(o.t.invoiced),
              received: money(o.t.received),
              outstanding: (
                <>
                  {money(o.t.outstanding)}
                  {o.t.unpaid > 0 && <div className="lock">{o.t.unpaid} unpaid</div>}
                </>
              ),
              reconcile:
                o.reconcile && o.t.unpaid > 0 ? (
                  <Link className="btn ghost" href={`/billing?tab=invoices&reconcile=${o.key}`} style={{ textDecoration: "none", whiteSpace: "nowrap" }}>
                    Reconcile
                  </Link>
                ) : null,
            },
          }))}
          empty="No billing offices are on file."
        />
      </div>
      <p className="lock" style={{ margin: "0 0 18px" }}>
        Hours, invoiced and received are this month&apos;s. Outstanding is every invoice sent and not yet paid,
        whenever it was raised. The billing files below lead with the billing office and are grouped by it.
      </p>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="files"
          columns={[
            { key: "file", label: "File" },
            { key: "download", label: "", sortable: false },
          ]}
          rows={kinds.map((k) => ({
            key: k.key,
            text: `${k.label} ${k.detail}`,
            sort: { file: k.label },
            cells: {
              file: (
                <>
                  <b>{k.label}</b>
                  <div className="lock">{k.detail}</div>
                </>
              ),
              download: (
                <a className="btn ghost" href={link(k.key)} style={{ textDecoration: "none", whiteSpace: "nowrap" }}>
                  Download CSV
                </a>
              ),
            },
          }))}
          empty="There is no export your role can take."
        />
      </div>

      <p className="lock" style={{ marginTop: 10 }}>
        Each file is read through your own account, so it contains exactly what you can see on the
        screens — no more. Nothing restricted is exported at all: no dates of birth, no addresses,
        no tax numbers, whoever asks. Prepared {today()}.{" "}
        {me.role === "Admin" && <Link href="/admin/people#contractors">Contractor statements</Link>}
      </p>
    </>
  );
}
