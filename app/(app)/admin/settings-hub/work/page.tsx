import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { ROLE_NAMES, ROLE_LABEL } from "@/lib/roles";
import { RecordHeader } from "../../../record-header";
import { MileageRateForm } from "../../../hours/expenses";

/**
 * What people log their work against, and what a mile is worth
 * (Design language, §3).
 *
 * The categories are rows rather than code (0134), and each one can name the
 * roles it is offered to. This page says what the list is; changing it is a
 * row, which is why it is shown rather than edited here - the practice has
 * changed it twice in a year, and a form for something changed twice a year
 * is a form nobody remembers how to use.
 */
export default async function WorkSettings() {
  await requireAdmin();
  const supabase = await createClient();

  const [{ data: categories }, { data: rates }] = await Promise.all([
    supabase.from("work_categories").select("key, label, detail, billable, roles, active").order("sort_order"),
    supabase.from("mileage_rates").select("effective_from, cents_per_mile, note").order("effective_from", { ascending: false }),
  ]);

  return (
    <>
      <RecordHeader
        back={{ href: "/admin/settings-hub", label: "Settings" }}
        title="Work and hours"
        standing="What people log against, and what a mile is worth"
      />

      <section className="page-section">
        <h2 className="h2">Categories</h2>
        <p className="sub">
          What an hour can be logged against. A category with no roles named is offered to everybody; Admin is offered
          all of them whatever they say.
        </p>
        <div className="card" style={{ padding: 0 }}>
          <table className="t" data-layout="the work categories: what each is, who is offered it, and whether it is billable">
            <thead>
              <tr>
                <th>Category</th>
                <th>Offered to</th>
                <th>Billable</th>
              </tr>
            </thead>
            <tbody>
              {(categories ?? []).map((c) => (
                <tr key={c.key}>
                  <td>
                    {c.label}
                    {c.detail && <div className="lock">{c.detail}</div>}
                  </td>
                  <td className="lock">
                    {(c.roles ?? []).length === 0
                      ? "everybody"
                      : (c.roles ?? [])
                          .map((r) => ROLE_LABEL[r as (typeof ROLE_NAMES)[number]] ?? r)
                          .join(", ")}
                  </td>
                  <td className="lock">{c.billable ? "yes" : "no"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </section>

      <section className="page-section">
        <h2 className="h2">Mileage rate</h2>
        <p className="sub">
          What a mile claimed on Hours is paid at. Rates are dated, so a claim is priced at the rate that applied on the
          day it was driven.
        </p>
        <MileageRateForm rates={(rates ?? []) as never} today={today()} />
      </section>
    </>
  );
}
