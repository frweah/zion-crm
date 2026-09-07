import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import {
  ProfileEditor,
  PaymentForm,
  DeletePayment,
  TaxYearEditor,
  type ProfileRow,
  type TaxYearRow,
} from "./contractor-forms";

const usd = (n: number) => n.toLocaleString("en-US", { style: "currency", currency: "USD" });

export default async function ContractorsPage({
  searchParams,
}: {
  searchParams: Promise<{ year?: string }>;
}) {
  await requireAdmin();
  const supabase = await createClient();

  const params = await searchParams;
  const thisYear = Number(today().slice(0, 4));
  const year = Number(params.year) || thisYear;

  const [staffResult, profilesResult, paymentsResult, totalsResult, yearsResult, statementsResult] =
    await Promise.all([
      supabase
        .from("staff")
        .select("id, name, active")
        .eq("active", true)
        .order("name"),
      supabase.from("contractor_profiles").select("*"),
      supabase
        .from("contractor_payments")
        .select("id, staff_id, paid_on, amount, method, reference, note, statement_id")
        .gte("paid_on", `${year}-01-01`)
        .lte("paid_on", `${year}-12-31`)
        .order("paid_on", { ascending: false }),
      supabase.from("contractor_year_totals").select("*").eq("year", year),
      supabase.from("tax_years").select("*").order("year", { ascending: false }),
      supabase
        .from("contractor_statements")
        .select("id, staff_id, period_start, period_end, status")
        .order("period_start", { ascending: false })
        .limit(50),
    ]);

  const staff = staffResult.data ?? [];
  const staffName = new Map(staff.map((s) => [s.id, s.name]));
  const profiles = profilesResult.data ?? [];
  const payments = paymentsResult.data ?? [];
  const totals = new Map((totalsResult.data ?? []).map((t) => [t.staff_id, Number(t.total_paid)]));
  const years = yearsResult.data ?? [];

  // Everyone active who is not the owner is a possible payee. The profile is
  // created on first save rather than being required up front, so the list
  // comes from the roster rather than from who happens to have one already.
  const profileByStaff = new Map(profiles.map((p) => [p.staff_id, p]));
  const rows: ProfileRow[] = staff.map((s) => {
    const p = profileByStaff.get(s.id);
    return {
      staff_id: s.id,
      name: s.name,
      legal_name: p?.legal_name ?? "",
      business_name: p?.business_name ?? "",
      address_line1: p?.address_line1 ?? "",
      address_line2: p?.address_line2 ?? "",
      city: p?.city ?? "",
      state: p?.state ?? "",
      postal_code: p?.postal_code ?? "",
      tax_status: p?.tax_status ?? "US person",
      tin_type: p?.tin_type ?? null,
      tin_last4: p?.tin_last4 ?? null,
      w9_received_on: p?.w9_received_on ?? null,
      w8ben_received_on: p?.w8ben_received_on ?? null,
      w8ben_expires_on: p?.w8ben_expires_on ?? null,
      notes: p?.notes ?? "",
    };
  });

  const statements = (statementsResult.data ?? []).map((s) => ({
    id: s.id,
    staff_id: s.staff_id,
    label: `${s.period_start} to ${s.period_end} · ${s.status}`,
  }));

  const yearRows: TaxYearRow[] = years.map((y) => ({
    year: y.year,
    federal_threshold: y.federal_threshold,
    utah_state_copy: y.utah_state_copy,
    confirmed_on: y.confirmed_on,
    confirmed_by_name: y.confirmed_by ? (staffName.get(y.confirmed_by) ?? null) : null,
    notes: y.notes,
  }));

  const yearTotal = payments.reduce((sum, p) => sum + Number(p.amount), 0);
  const paidThisYear = [...totals.entries()].filter(([, amount]) => amount > 0);

  return (
    <>
      <h1 className="h1">Contractors</h1>
      <p className="sub">
        Who is paid, what they were paid, and the details a 1099 needs. Everything here is Admin
        only, in the database as well as on this screen.
      </p>

      <h3 style={{ marginTop: 18 }}>Details for a 1099</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A signed W-9 fills most of this in by itself. What is here is for the parts it does not
        carry, and for people who gave you a form on paper.
      </p>
      {rows.map((r) => (
        <ProfileEditor key={r.staff_id} row={r} />
      ))}

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 1fr) minmax(300px, 380px)" }}>
        <div>
          <PaymentForm
            contractors={staff.map((s) => ({ id: s.id, name: s.name }))}
            statements={statements}
            defaultDate={today()}
          />

          <div className="card" style={{ marginTop: 14, padding: 0 }}>
            <h3 style={{ padding: "16px 16px 0" }}>Payments in {year}</h3>
            <table className="t">
              <thead>
                <tr>
                  <th>Paid</th>
                  <th>Who</th>
                  <th>Amount</th>
                  <th>Method</th>
                  <th>Reference</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {payments.length === 0 && (
                  <tr>
                    <td colSpan={6} className="empty">
                      Nothing recorded for {year}.
                    </td>
                  </tr>
                )}
                {payments.map((p) => (
                  <tr key={p.id}>
                    <td>{p.paid_on}</td>
                    <td>{staffName.get(p.staff_id) ?? "—"}</td>
                    <td>{usd(Number(p.amount))}</td>
                    <td>{p.method}</td>
                    <td style={{ fontSize: 12, color: "var(--muted)" }}>
                      {p.reference || "—"}
                      {p.note && <div>{p.note}</div>}
                    </td>
                    <td>
                      <DeletePayment id={p.id} amount={Number(p.amount)} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
            {payments.length > 0 && (
              <p className="lock" style={{ padding: "0 16px 16px" }}>
                {payments.length} payment{payments.length === 1 ? "" : "s"} totalling{" "}
                {usd(yearTotal)} in {year}.
              </p>
            )}
          </div>
        </div>

        <div>
          <div className="card">
            <h3>Paid in {year}</h3>
            {paidThisYear.length === 0 ? (
              <p className="sub" style={{ margin: 0 }}>
                Nobody has been paid in {year} yet.
              </p>
            ) : (
              <table className="t">
                <tbody>
                  {paidThisYear
                    .sort((a, b) => b[1] - a[1])
                    .map(([staffId, amount]) => (
                      <tr key={staffId ?? ""}>
                        <td>{(staffId && staffName.get(staffId)) ?? "—"}</td>
                        <td style={{ textAlign: "right" }}>{usd(amount)}</td>
                      </tr>
                    ))}
                </tbody>
              </table>
            )}
            <p className="lock" style={{ marginBottom: 0 }}>
              Calendar-year totals, which is the figure that goes in box 1.
            </p>
          </div>

          <h3 style={{ marginTop: 18 }}>Tax year settings</h3>
          {yearRows.map((y) => (
            <TaxYearEditor key={y.year} row={y} />
          ))}
        </div>
      </div>
    </>
  );
}
