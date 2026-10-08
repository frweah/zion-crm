import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import { DataTable } from "../../../data-table";

/**
 * The CRP rate schedule (§13.13).
 *
 * It was on Billing → Export, which §9 removed. Nobody billing needs to read
 * it: the authorization is priced from it and shows the rate, and asks for one
 * only when the PDF says something different. It is here because it is the
 * reference the pricing comes from, and keeping it where the totals are means
 * the person who maintains it is the person looking at what it produced.
 *
 * Keyed by funding source, so a second funder needs no code change.
 */
export default async function RateSchedule() {
  const supabase = await createClient();
  const { data: rates } = await supabase
    .from("rate_schedule")
    .select("service, sub, fee, unit, funding_source")
    .order("service");

  return (
    <>
      <h2 className="h2">Rate schedule</h2>
      <p className="sub">
        What each service is worth, from the Voc Rehab Workbook. New authorizations are priced from
        it.
      </p>
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="rates"
          columns={[
            { key: "service", label: "Service" },
            { key: "sub", label: "Subcategory" },
            { key: "fee", label: "Approved fee", align: "right" },
            { key: "unit", label: "Unit" },
            { key: "funder", label: "Funder" },
          ]}
          rows={(rates ?? []).map((r, i) => ({
            key: `${r.funding_source}-${r.service}-${r.sub}-${i}`,
            sort: { fee: Number(r.fee) },
            cells: {
              service: r.service,
              sub: r.sub,
              fee: money(r.fee),
              unit: r.unit,
              funder: r.funding_source,
            },
          }))}
          empty="The rate schedule is empty."
        />
      </div>
    </>
  );
}
