import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { DataTable } from "../../data-table";
import { ProfileEditor, PaymentForm, DeletePayment, type ProfileRow } from "./contractor-forms";
import { GenerateRun, RunPanel, type RecipientRow } from "./run-forms";

const usd = (n: number) => n.toLocaleString("en-US", { style: "currency", currency: "USD" });

/**
 * Contractors: HR → Contractors, the second half of the People screen.
 *
 * The details a 1099 needs, the payments made, and the runs built from them.
 * The per-person details and the runs are each one list with an item apiece,
 * because every item carries its own form; the payments are the one table.
 */
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
        .eq("active", true).eq("is_system", false)
        .order("name"),
      // Named rather than "*": tin_encrypted is not readable by the app role,
      // and "*" expands to it and is refused outright. See migration 0039.
      supabase
        .from("contractor_profiles")
        .select(
          "staff_id, legal_name, business_name, address_line1, address_line2, city, state, postal_code, tax_status, tin_type, tin_last4, w9_received_on, w8ben_received_on, w8ben_expires_on, e_delivery_consent_on, notes",
        ),
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

  // The 1099 year is the one just gone: runs are built in January for the year
  // that ended. Candidates are read for the same year so the screen can say
  // why a run cannot be built yet rather than only that the button is off.
  const filingYear = year - 1;
  const [runsResult, recipientsResult, candidatesResult] = await Promise.all([
    supabase
      .from("form_1099_runs")
      .select("id, year, threshold, state_copy, generated_at, filed_on, iris_receipt, notes")
      .order("generated_at", { ascending: false })
      .limit(10),
    supabase
      .from("form_1099_recipients")
      .select(
        "id, run_id, legal_name, business_name, address_snapshot, tin_type, tin_last4, nonemployee_comp, consent_recorded, delivered_on, delivery_method",
      )
      .order("legal_name"),
    supabase.rpc("form_1099_candidates", { p_year: filingYear }),
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

  const yearTotal = payments.reduce((sum, p) => sum + Number(p.amount), 0);
  const paidThisYear = [...totals.entries()]
    .filter(([, amount]) => amount > 0)
    .sort((a, b) => b[1] - a[1]);

  const runs = runsResult.data ?? [];
  const recipientsByRun = new Map<string, RecipientRow[]>();
  for (const r of recipientsResult.data ?? []) {
    const list = recipientsByRun.get(r.run_id) ?? [];
    list.push(r as RecipientRow);
    recipientsByRun.set(r.run_id, list);
  }

  // Why a run cannot be built is worth saying out loud. "The button is off" is
  // not something anyone can act on in the week a filing is due.
  const filingYearSettings = years.find((y) => y.year === filingYear);
  const candidates = (candidatesResult.data ?? []) as {
    staff_name: string;
    ready: boolean;
    problem: string | null;
  }[];
  const notReady = candidates.filter((c) => !c.ready);

  const canRun =
    Boolean(filingYearSettings?.confirmed_on) && candidates.length > 0 && notReady.length === 0;

  const why = !filingYearSettings
    ? `There are no settings for ${filingYear} yet. Tax years are set in Admin → System.`
    : filingYearSettings.federal_threshold == null
      ? `The ${filingYear} federal threshold has not been set. Ask the CPA, then enter it in Admin → System → Tax years.`
      : !filingYearSettings.confirmed_on
        ? `The ${filingYear} threshold has been entered but not confirmed. Nothing is filed on an unconfirmed figure.`
        : candidates.length === 0
          ? `Nobody was paid ${usd(Number(filingYearSettings.federal_threshold))} or more in ${filingYear}.`
          : `Not ready to file: ${notReady.map((c) => `${c.staff_name} (${c.problem})`).join("; ")}.`;

  return (
    <>
      <h2 className="h2">Contractors</h2>
      <p className="sub">
        Who is paid, what they were paid, and the details a 1099 needs. Everything here is Admin
        only, in the database as well as on this screen.
      </p>

      <h3 style={{ marginTop: 18 }}>Details for a 1099</h3>
      <p className="sub" style={{ marginTop: 0 }}>
        A signed W-9 fills most of this in by itself. What is here is for the parts it does not
        carry, and for people who gave you a form on paper.
      </p>
      {rows.length === 0 ? (
        <p className="empty">There is nobody active on the staff list to pay.</p>
      ) : (
        // Sortable by name, tax status or when the W-9 or W-8BEN came in; each
        // row opens to its own editor.
        <div className="card" style={{ padding: 0, marginBottom: 16 }}>
          <DataTable
            label="contractors"
            columns={[
              { key: "who", label: "Contractor", sortLabel: "Name" },
              { key: "status", label: "Tax status" },
              { key: "w9", label: "W-9 received" },
              { key: "w8", label: "W-8BEN good to" },
            ]}
            rows={rows.map((r) => ({
              key: r.staff_id,
              sort: {
                who: r.name,
                status: r.tax_status || "US person",
                w9: r.w9_received_on,
                w8: r.w8ben_expires_on,
              },
              text: [r.name, r.tax_status].filter(Boolean).join(" "),
              cells: {
                who: <ProfileEditor row={r} />,
                status: r.tax_status || "US person",
                w9: <span style={{ whiteSpace: "nowrap" }}>{r.w9_received_on ?? "—"}</span>,
                w8: <span style={{ whiteSpace: "nowrap" }}>{r.w8ben_expires_on ?? "—"}</span>,
              },
            }))}
            empty="There is nobody active on the staff list to pay."
          />
        </div>
      )}

      <div className="grid" style={{ gridTemplateColumns: "minmax(0, 1fr) minmax(300px, 380px)" }}>
        <div>
          <PaymentForm
            contractors={staff.map((s) => ({ id: s.id, name: s.name }))}
            statements={statements}
            defaultDate={today()}
          />

          <h3 style={{ marginTop: 18 }}>Payments in {year}</h3>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="payments"
              columns={[
                { key: "paid", label: "Paid" },
                { key: "who", label: "Who" },
                { key: "amount", label: "Amount", align: "right" },
                { key: "method", label: "Method" },
                { key: "reference", label: "Reference" },
                { key: "remove", label: "", sortable: false },
              ]}
              rows={payments.map((p) => {
                const who = staffName.get(p.staff_id) ?? "—";
                return {
                  key: p.id,
                  text: `${p.paid_on} ${who} ${p.method} ${p.reference ?? ""} ${p.note ?? ""}`,
                  sort: { amount: Number(p.amount), reference: p.reference },
                  cells: {
                    paid: p.paid_on,
                    who,
                    amount: usd(Number(p.amount)),
                    method: p.method,
                    reference: (
                      <span className="lock">
                        {p.reference || "—"}
                        {p.note && <div>{p.note}</div>}
                      </span>
                    ),
                    remove: <DeletePayment id={p.id} amount={Number(p.amount)} />,
                  },
                };
              })}
              empty={`Nothing has been recorded for ${year}.`}
            />
            {payments.length > 0 && (
              <p className="lock" style={{ margin: 0, padding: "10px 14px 14px" }}>
                {payments.length} payment{payments.length === 1 ? "" : "s"} totalling{" "}
                {usd(yearTotal)} in {year}.
              </p>
            )}
          </div>
        </div>

        <div>
          <h3 style={{ marginTop: 0 }}>Paid in {year}</h3>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="contractors"
              columns={[
                { key: "who", label: "Who" },
                { key: "paid", label: "Box 1", align: "right" },
              ]}
              rows={paidThisYear.map(([staffId, amount]) => ({
                key: staffId ?? "",
                sort: { who: (staffId && staffName.get(staffId)) ?? "", paid: amount },
                cells: {
                  who: (staffId && staffName.get(staffId)) ?? "—",
                  paid: usd(amount),
                },
              }))}
              empty={`Nobody has been paid in ${year} yet.`}
            />
          </div>
          <p className="lock" style={{ marginTop: 8 }}>
            Calendar-year totals, which is the figure that goes in box 1.
          </p>

          {/* A setting, so it lives in Admin → System; a 1099 run reads it from there. */}
          <p className="lock" style={{ marginTop: 14 }}>
            The federal threshold and state copy for each tax year are set in{" "}
            <a href="/admin/system#tax-years">Admin → System → Tax years</a>.
          </p>
        </div>
      </div>

      <h3 style={{ marginTop: 24 }}>1099-NEC</h3>
      <GenerateRun year={filingYear} canRun={canRun} why={why} />

      {runs.length > 0 ? (
        <div className="list" style={{ marginTop: 14 }}>
          {runs.map((run) => (
            <RunPanel
              key={run.id}
              run={run}
              recipients={recipientsByRun.get(run.id) ?? []}
              defaultDate={today()}
            />
          ))}
        </div>
      ) : (
        <p className="sub" style={{ marginTop: 14 }}>
          No run has been built yet. January 31 is the deadline for both giving contractors their
          copies and filing with the IRS.
        </p>
      )}
    </>
  );
}
