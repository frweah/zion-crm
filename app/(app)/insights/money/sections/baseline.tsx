import { createClient } from "@/lib/supabase/server";
import { BaselinePanel, type BaselineRow } from "./baseline-panel";

/**
 * Where the practice stood (0219).
 *
 * The books open on 1 January 2027, so everything done in 2026 is outside the
 * ledger and there would otherwise be nothing to say what came before. A
 * baseline is counted once and kept, which is what makes it a baseline: if it
 * were worked out again each time, an authorization corrected in March would
 * quietly change what December said.
 */
export default async function BaselineSection() {
  const supabase = await createClient();

  const [{ data: rows }, { data: settings }] = await Promise.all([
    supabase
      .from("money_baselines")
      .select(
        "id, as_of, label, authorized, earned, invoiced, received, outstanding, unbilled, clients, authorizations, documents, hours, taken_at, note",
      )
      .order("as_of", { ascending: false })
      .limit(20),
    supabase.from("ledger_settings").select("books_start").maybeSingle(),
  ]);

  const taken: BaselineRow[] = (rows ?? []).map((r) => ({
    id: r.id,
    asOf: r.as_of,
    label: r.label,
    authorized: Number(r.authorized),
    earned: Number(r.earned),
    invoiced: Number(r.invoiced),
    received: Number(r.received),
    outstanding: Number(r.outstanding),
    unbilled: Number(r.unbilled),
    clients: r.clients,
    authorizations: r.authorizations,
    documents: r.documents,
    hours: Number(r.hours),
    takenAt: r.taken_at,
    note: r.note,
  }));

  return <BaselinePanel rows={taken} booksStart={settings?.books_start ?? null} />;
}
