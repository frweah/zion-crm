import { can } from "@/lib/roles";
import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";

import { InboxView, type PendingRow, type Placeholder } from "./inbox-view";

/**
 * The document inbox, a section of Admin → Documents - Admin's alone.
 *
 * An agent on the owner's machine posts every PDF from the client folders.
 * Nothing it sends is filed on arrival — this is where a person looks at what
 * arrived and says what it is. The authorizations in it are Billing's to
 * confirm too, on Billing → Authorizations, which is also where the agent's
 * status is shown (./agent-status.tsx). The database holds the same line
 * (0103): Billing reads the authorizations and nothing else here.
 */
export default async function InboxSection() {
  const me = await requireStaff();
  /**
   * Admin, or somebody holding a billing edit grant (owner, 23 Oct 2026).
   *
   * This used to redirect everybody who was not Admin and then, on the very
   * next line, work out whether they held the grant - a question that could
   * only ever be asked of an Admin. The grant meant one thing here and
   * another in the database, where `inbox_documents` has opened the
   * authorization documents to a billing edit grant since 0103.
   *
   * The database is still what limits them: a grantee reads and writes the
   * authorizations in this inbox and nothing else in it, so the section is
   * safe to draw for them without a second rule here deciding which rows.
   */
  const canBill = can(me, "billing", "edit");
  if (me.role !== "Admin" && !canBill) redirect("/dashboard");

  const supabase = await createClient();

  const [pendingResult, clientsResult, doneResult, placeholderResult] = await Promise.all([
    supabase.from("inbox_pending").select("*").order("first_seen", { ascending: false }),
    supabase.from("clients").select("id, name").order("name"),
    supabase.from("inbox_documents").select("state").neq("state", "Pending"),
    // Authorizations USOR has not numbered yet, which a confirmed scan can
    // replace. One definition, on the row (0251).
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, carried_used, total_hours")
      .eq("has_usor_number", false),
  ]);

  const pending = (pendingResult.data ?? []) as unknown as PendingRow[];
  const done = doneResult.data ?? [];

  return (
    <>
      <h2 className="h2">Document inbox</h2>
      <p className="sub">
        Everything the agent has found in the client folders, waiting for somebody to say what it
        is. Warrant stubs in the _Warrants folder never come here: they are read line by line on{" "}
        <Link href="/billing#warrant-review">Billing → Authorizations</Link>.
        {canBill && (
          <>
            {" "}
            Billing confirms the authorizations from here on{" "}
            <Link href="/billing?tab=authorizations#from-documents">Billing → Authorizations</Link>, where
            the agent's status is too.
          </>
        )}
      </p>

      <div
        className="grid"
        style={{ gridTemplateColumns: "repeat(auto-fit, minmax(180px, 1fr))", marginBottom: 18 }}
      >
        <div className="card">
          <div className="stat" style={pending.length > 0 ? { color: "var(--gold)" } : undefined}>
            {pending.length}
            <small>waiting for somebody</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {done.filter((d) => d.state === "Filed").length}
            <small>filed</small>
          </div>
        </div>
        <div className="card">
          <div className="stat">
            {done.filter((d) => d.state === "Ignored").length}
            <small>set aside</small>
          </div>
        </div>
      </div>

      <InboxView
        pending={pending}
        clients={clientsResult.data ?? []}
        canBill={canBill}
        placeholders={(placeholderResult.data ?? []) as Placeholder[]}
      />

      <p className="lock" style={{ marginTop: 14 }}>
        The agent only reads. Renaming or reorganising the folders is safe.</p>
    </>
  );
}
