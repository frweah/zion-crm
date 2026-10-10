import { requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../record-header";
import { AssetRegister } from "./asset-register";

/**
 * The asset register (ERP brief, E4).
 *
 * What the practice owns, who has it, what it cost and what it is worth now.
 * The book value is not stored: it is the cost less what has been
 * depreciated, and the depreciation is postings, so this screen and the
 * balance sheet cannot disagree.
 *
 * The lives are the CPA's to set. Changing one changes what next month
 * posts; it never rewrites a month already posted, because that month has
 * been reported on.
 */
export default async function Assets() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: register }, { data: classes }, { data: staff }, { data: history }] =
    await Promise.all([
      supabase.rpc("asset_register", { p_as_of: null }),
      supabase.from("asset_classes").select("key, label, life_months, capitalise_over").order("sort_order"),
      supabase.from("staff").select("id, name").eq("active", true).order("name"),
      supabase
        .from("asset_assignments")
        .select("asset_id, staff_name, from_date, to_date, note")
        .order("from_date", { ascending: false })
        .limit(300),
    ]);

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Equipment"
        standing={`${((register ?? []) as { status: string }[]).filter((a) => a.status !== "Disposed").length} on the register`}
      />
      <AssetRegister
        assets={(register ?? []) as never}
        classes={(classes ?? []) as never}
        staff={(staff ?? []) as { id: string; name: string }[]}
        history={(history ?? []) as never}
        isAdmin={me.role === "Admin"}
      />
    </>
  );
}
