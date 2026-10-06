import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { fmtStamp } from "@/lib/constants";
import { PageHead } from "../page-head";
import { FormFiller, type PracticeForm } from "./form-filler";

/**
 * The practice's own forms (Design language, §3).
 *
 * A client visit, a worksite check, an incident: the things that were paper,
 * or a note typed into Activity, or nothing. Filled in on a phone and saved
 * against the client, where the next person to open that record will find
 * them.
 *
 * USOR's forms are not here. Those are somebody else's document with somebody
 * else's rules, they live on Billing, and they already work.
 */
export default async function FormsAndChecklistsPage() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [{ data: forms }, { data: clients }, { data: recent }] = await Promise.all([
    supabase.from("practice_forms").select("key, name, purpose, fields, about_a_client").order("sort_order"),
    supabase.from("clients").select("id, name").eq("status", "Active").order("name"),
    supabase
      .from("practice_form_entries")
      .select("id, form_key, client_id, staff_name, filled_at")
      .order("filled_at", { ascending: false })
      .limit(12),
  ]);

  const names = new Map((clients ?? []).map((c) => [c.id, c.name]));
  const formName = new Map((forms ?? []).map((f) => [f.key, f.name]));

  return (
    <>
      <PageHead
        title="Forms and checklists"
        context="The practice's own, filled in where the work happens"
      />

      <div className="hub-cards">
        {((forms ?? []) as unknown as PracticeForm[]).map((f) => (
          <FormFiller key={f.key} form={f} clients={clients ?? []} />
        ))}
      </div>

      <section className="page-section">
        <h2 className="h2">Lately</h2>
        {(recent ?? []).length === 0 ? (
          <p className="empty">Nothing has been filled in yet.</p>
        ) : (
          <ul className="day-list">
            {(recent ?? []).map((e) => (
              <li key={e.id}>
                <span className="chip">{formName.get(e.form_key) ?? e.form_key}</span>
                <span className="day-main">
                  {e.client_id ? (
                    <Link href={`/clients/${e.client_id}`}>
                      <b>{names.get(e.client_id) ?? "A client"}</b>
                    </Link>
                  ) : (
                    <b>The practice</b>
                  )}
                  <span className="lock"> by {e.staff_name ?? "somebody"}</span>
                </span>
                <span className="lock day-when">{fmtStamp(e.filled_at)}</span>
              </li>
            ))}
          </ul>
        )}
      </section>

      <p className="lock">
        USOR&rsquo;s own forms — the 95, the 93, the 60 and 92 — are on{" "}
        <Link href="/billing/forms">Billing → Forms</Link>, where they have always been.
      </p>
    </>
  );
}
