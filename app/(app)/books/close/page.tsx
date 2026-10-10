import { readSettings, requireBooks } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { RecordHeader } from "../../record-header";
import { ClosingForms } from "./closing-forms";

/**
 * Closing (ERP brief, E1).
 *
 * A month is closed when it is finished and reported on, and after that a
 * posting dated inside it is refused. Reopening is Admin's and is written
 * down in the access log, because "who changed March after we filed" is a
 * question that gets asked once and has to have an answer.
 *
 * The year-end package is every report for the year plus the 1099 tie-out,
 * as files, zipped. The tie-out is the part worth looking at: three numbers
 * that have to be the same, and the time to find out they are not is
 * December rather than the following August.
 */
export default async function Closing() {
  await requireBooks();
  const me = await requireStaff();
  const supabase = await createClient();

  const [settings, { data: closed }, { data: posted }, { data: years }] = await Promise.all([
    readSettings(supabase),
    supabase
      .from("ledger_periods")
      .select("month, closed_at, closed_by_name, note")
      .order("month", { ascending: false }),
    supabase.from("journals").select("entry_date").order("entry_date").limit(1),
    supabase.from("journals").select("entry_date").order("entry_date", { ascending: false }).limit(1),
  ]);

  const first = (posted ?? [])[0]?.entry_date as string | undefined;
  const last = (years ?? [])[0]?.entry_date as string | undefined;
  const yearList = first && last
    ? Array.from(
        { length: Number(last.slice(0, 4)) - Number(first.slice(0, 4)) + 1 },
        (_, i) => Number(first.slice(0, 4)) + i,
      ).reverse()
    : [];

  return (
    <>
      <RecordHeader
        back={{ href: "/books", label: "Books" }}
        title="Closing"
        standing={
          settings ? `${settings.basis} basis, open from ${settings.books_start}` : "Not set up yet"
        }
      />
      <ClosingForms
        isAdmin={me.role === "Admin"}
        settings={settings}
        anythingPosted={Boolean(first)}
        closed={(closed ?? []) as { month: string; closed_at: string; closed_by_name: string; note: string }[]}
        years={yearList}
      />
    </>
  );
}
