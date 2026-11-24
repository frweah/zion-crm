import Link from "next/link";
import { ADD_AUTHORIZATION } from "@/lib/roles";
import { redirect } from "next/navigation";
import { requireStaff } from "@/lib/session";
import { can } from "@/lib/roles";
import { PageHead } from "../../page-head";
import InboxSection from "../inbox/section";
import { RunNowButton } from "../inbox/run-now-button";
import { createClient } from "@/lib/supabase/server";
import RetentionSection from "../retention/section";
import RecordsRequestSection from "../records-request/section";

/**
 * Admin → Documents.
 *
 * What arrives, what is kept, and what goes out: the document inbox - folders
 * nobody has claimed, warrant stubs, invoices, USOR forms, anything unreadable
 * - then how long records are kept and the requests for a person's file.
 *
 * Admin's, except the inbox (owner, 23 Oct 2026). `inbox_documents` has
 * opened the authorization documents to a billing edit grant since 0103, and
 * the screen said Admin only - so the grant meant one thing in the database
 * and another here, and the person holding it had no way to reach the
 * "Replace with this number" action at all. Retention and records requests
 * stay Admin's: those are about the practice's own obligations rather than
 * about billing a client.
 */
export default async function DocumentsPage() {
  const me = await requireStaff();
  const canBill = can(me, "billing", "edit");
  if (me.role !== "Admin" && !canBill) redirect("/dashboard");
  const admin = me.role === "Admin";

  /**
   * Whether an extra pass is already waiting on the agent (0382).
   *
   * Read here rather than inside the button, so the button is told and does
   * not ask: a second press before the agent has woken would write a second
   * row that one pass answers, and the record would read as two passes.
   */
  const supabase = await createClient();
  const { data: waiting } = await supabase
    .from("inbox_scan_requests")
    .select("asked_by_name")
    .is("done_at", null)
    .order("asked_at")
    .limit(1)
    .maybeSingle();

  return (
    <>
      <PageHead
        title="Document inbox &amp; retention"
        context="What has arrived and is waiting, how long records are kept, and requests for a person's file"
        actions={
          <div className="row2" style={{ gap: 8, flexWrap: "wrap", alignItems: "baseline" }}>
            {/* The agent reads the folders at ten and at seven (23 November
                2026). This asks it to read them on its next wake instead,
                which is within fifteen minutes. */}
            <RunNowButton waiting={Boolean(waiting)} askedBy={waiting?.asked_by_name ?? ""} />
            <Link className="btn ghost" href={ADD_AUTHORIZATION} style={{ textDecoration: "none" }}>
              Read an authorization PDF
            </Link>
          </div>
        }
        toc={
          admin
            ? [
                ["inbox", "Document inbox"],
                ["retention", "Retention"],
                ["records-requests", "Records requests"],
              ]
            : [["inbox", "Document inbox"]]
        }
      />

      <section id="inbox" className="page-section">
        <InboxSection />
      </section>

      {admin && (
        <>
          <section id="retention" className="page-section">
            <RetentionSection />
          </section>

          <section id="records-requests" className="page-section">
            <RecordsRequestSection />
          </section>
        </>
      )}
    </>
  );
}
