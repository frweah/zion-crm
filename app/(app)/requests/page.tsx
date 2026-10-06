import { readSettings } from "@/lib/books";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { PageHead } from "../page-head";
import { RequestsView } from "./requests-view";

/**
 * Asking before spending (ERP brief, E3).
 *
 * Off until the owner sets an amount, and the screen says so rather than
 * pretending to be a feature: a form nobody has to use is a form people fill
 * in anyway and then wonder why nothing happens.
 *
 * Not inside Books. Books is for the two people who keep them; asking to buy
 * a laptop is everybody's, and a screen only Admin and Billing can open
 * would be a screen the person who needs it cannot reach.
 */
export default async function Requests() {
  const me = await requireStaff();
  const supabase = await createClient();

  const [settings, { data: rows }] = await Promise.all([
    readSettings(supabase),
    supabase
      .from("purchase_requests")
      .select("id, what, why, amount, status, decision_note, created_at, decided_at, staff_id, staff(name)")
      .order("created_at", { ascending: false })
      .limit(100),
  ]);

  const over = settings?.purchase_request_over ?? null;

  return (
    <>
      <PageHead
        title="Purchase requests"
        context={over === null ? "Nothing needs asking for" : `Anything over ${over}`}
      />
      <RequestsView
        over={over}
        approvalLimit={settings?.bill_approval_limit ?? null}
        isAdmin={me.role === "Admin"}
        myId={me.id}
        requests={(rows ?? []) as never}
      />
    </>
  );
}
