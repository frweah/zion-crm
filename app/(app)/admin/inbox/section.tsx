import { can } from "@/lib/roles";
import Link from "next/link";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";

import { InboxView, type PendingRow, type Placeholder } from "./inbox-view";

/**
 * The document inbox, a section of Admin → Documents.
 *
 * An agent on the owner's machine posts every PDF from the client folders.
 * Nothing it sends is filed on arrival — this is where a person looks at what
 * arrived and says what it is. Whether the agent is running is shown in
 * Admin → System (./agent-status.tsx).
 */
const CAN_REVIEW = ["Admin", "Billing", "Job Search", "Reports"];

export default async function InboxSection() {
  const me = await requireStaff();
  if (!CAN_REVIEW.includes(me.role)) redirect("/dashboard");
  const canBill = can(me, "billing", "edit");

  const supabase = await createClient();

  const [pendingResult, clientsResult, doneResult, placeholderResult] = await Promise.all([
    supabase.from("inbox_pending").select("*").order("first_seen", { ascending: false }),
    supabase.from("clients").select("id, name").order("name"),
    supabase.from("inbox_documents").select("state").neq("state", "Pending"),
    // Imported "(workbook)" authorizations, which a confirmed scan can replace.
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, carried_used, total_hours")
      .like("number", "(workbook)%"),
  ]);

  const pending = (pendingResult.data ?? []) as unknown as PendingRow[];
  const done = doneResult.data ?? [];

  return (
    <>
      <h2 className="h2">Document inbox</h2>
      <p className="sub">
        Everything the agent has found in the client folders, waiting for somebody to say what it
        is. Warrant stubs in the _Warrants folder never come here: they are read line by line on{" "}
        <Link href="/billing?tab=invoices#warrant-review">Billing → Invoices</Link>.
        {canBill && (
          <>
            {" "}
            Whether the agent is running: <Link href="/admin/system#agent">Admin → System</Link>.
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
        The agent reads the folder and nothing else. It has never moved, renamed or deleted a file,
        and it cannot — what stops a document arriving twice is its content, not its name, so
        renaming or reorganising the folders on the machine is safe.
      </p>
    </>
  );
}
