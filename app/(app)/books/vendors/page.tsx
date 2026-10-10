import { readChart, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../record-header";
import { VendorList } from "./vendor-list";

/**
 * Who the practice pays (ERP brief, E3).
 *
 * No tax number is kept here. A 1099-able vendor has a W-9, the W-9 lives in
 * the practice's documents, and what this records is that it is on file and
 * the last four digits - which is exactly what a 1099 snapshot stores anyway.
 * A second place to hold tax numbers would be a second thing to protect for
 * no gain at all.
 */
export default async function Vendors() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: vendors }, chart] = await Promise.all([
    supabase
      .from("vendors")
      .select(
        "id, name, contact_name, email, phone, terms_days, gets_1099, w9_on_file, w9_received_on, " +
          "tin_type, tin_last4, active, expense_account_id, note",
      )
      .order("name"),
    readChart(supabase),
  ]);

  const rows = (vendors ?? []) as unknown as { id: string; active: boolean }[];

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Vendors"
        standing={`${rows.filter((v) => v.active).length} in use`}
      />
      <VendorList
        vendors={(vendors ?? []) as never}
        accounts={chart.filter((a) => a.kind === "Expense" && a.active)}
        canEdit={me.role === "Admin" || me.role === "Billing"}
      />
    </>
  );
}
