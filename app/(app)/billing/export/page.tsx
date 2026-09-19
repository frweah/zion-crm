import { redirect } from "next/navigation";
import { can } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { money } from "@/lib/constants";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";
import ExportsSection from "../exports/section";

/**
 * Billing → Export.
 *
 * The month as files, and the CRP rate schedule new authorizations are
 * pre-filled from. Both were in Admin → System until Admin became Admin's
 * alone (owner, 19 Sept 2026); the old paths redirect here.
 */
export default async function BillingExportPage({
  searchParams,
}: {
  searchParams: Promise<{ month?: string }>;
}) {
  const me = await requireStaff();
  if (!can(me, "billing", "view")) redirect("/dashboard");

  const supabase = await createClient();
  const { data: rates } = await supabase
    .from("rate_schedule")
    .select("service, sub, fee, unit, funding_source")
    .order("service");

  return (
    <>
      <PageHead
        title="Export"
        context="The month as files, and the rate schedule authorizations are priced from"
        toc={[
          ["export", "Monthly export"],
          ["rates", "Rate schedule"],
        ]}
      />

      <section id="export" className="page-section">
        <ExportsSection searchParams={searchParams} />
      </section>

      <section id="rates" className="page-section">
        <h2 className="h2">Rate schedule</h2>
        <p className="sub">
          The CRP rate schedule from the Voc Rehab Workbook. New authorizations are pre-filled from it, and it is keyed
          by funding source so a second funder can be added without code changes.
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
      </section>
    </>
  );
}
