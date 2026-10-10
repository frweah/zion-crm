import { requireAdmin } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../../record-header";
import { TaxYearEditor, type TaxYearRow } from "../../contractors/contractor-forms";

/** What a 1099 run depends on (Design language, §3). */
export default async function TaxYearSettings() {
  await requireAdmin();
  const supabase = await createClient();

  const [{ data: years }, { data: staff }] = await Promise.all([
    supabase.from("tax_years").select("*").order("year", { ascending: false }),
    supabase.from("staff").select("id, name").eq("active", true).eq("is_system", false).order("name"),
  ]);
  const staffName = new Map(((staff ?? []) as { id: string; name: string }[]).map((s) => [s.id, s.name]));

  const rows: TaxYearRow[] = ((years ?? []) as {
    year: number;
    federal_threshold: number | null;
    utah_state_copy: boolean;
    confirmed_on: string | null;
    confirmed_by: string | null;
    notes: string;
  }[]).map((y) => ({
    year: y.year,
    federal_threshold: y.federal_threshold,
    utah_state_copy: y.utah_state_copy,
    confirmed_on: y.confirmed_on,
    confirmed_by_name: y.confirmed_by ? (staffName.get(y.confirmed_by) ?? null) : null,
    notes: y.notes,
  }));

  return (
    <>
      <RecordHeader
        back={{ href: "/admin/settings-hub", label: "Settings" }}
        title="Tax years"
        standing="What a 1099 run depends on"
      />
      <p className="sub">
        The federal 1099-NEC threshold and the Utah state copy for each year. A 1099 run will not build on a year whose
        threshold nobody has confirmed.
      </p>
      {rows.length === 0 ? (
        <div className="empty">No tax years are set up.</div>
      ) : (
        // One list, a year to an item: each is its own form, not a card apiece.
        <div className="list">
          {rows.map((y) => (
            <TaxYearEditor key={y.year} row={y} />
          ))}
        </div>
      )}
    </>
  );
}
