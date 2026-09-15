import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { CAN_EDIT_BILLING } from "@/lib/constants";
import { PageHead } from "../../page-head";
import InboxSection from "../inbox/section";
import RetentionSection from "../retention/section";
import RecordsRequestSection from "../records-request/section";

/**
 * Admin → Documents.
 *
 * What arrives, what is kept, and what goes out: the document inbox (every
 * role reviews it), then - for Admin - how long records are kept and the
 * requests for a person's file. Reading an authorization PDF is the header's
 * action for the roles that can. These were the Document inbox, Retention and
 * Records requests screens; the old paths redirect here.
 *
 * Warrant review is not here: it is money, and lives on Billing → Invoices.
 * Whether the documents agent is running is in Admin → System.
 */
export default async function DocumentsPage() {
  const me = await requireStaff();
  const isAdmin = me.role === "Admin";
  const canReadPdf = CAN_EDIT_BILLING.includes(me.role);

  const toc: [string, string][] = [["inbox", "Document inbox"]];
  if (isAdmin) toc.push(["retention", "Retention"], ["records-requests", "Records requests"]);

  return (
    <>
      <PageHead
        title="Documents"
        context={
          isAdmin
            ? "What has arrived and is waiting, how long records are kept, and requests for a person's file"
            : "What has arrived from the client folders and is waiting for somebody to say what it is"
        }
        actions={
          canReadPdf ? (
            <Link className="btn ghost" href="/billing/import" style={{ textDecoration: "none" }}>
              Read an authorization PDF
            </Link>
          ) : undefined
        }
        toc={toc}
      />

      <section id="inbox" className="page-section">
        <InboxSection />
      </section>

      {isAdmin && (
        <section id="retention" className="page-section">
          <RetentionSection />
        </section>
      )}

      {isAdmin && (
        <section id="records-requests" className="page-section">
          <RecordsRequestSection />
        </section>
      )}
    </>
  );
}
