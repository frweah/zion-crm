import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { CAN_EDIT_BILLING } from "@/lib/constants";
import InboxSection from "../inbox/section";
import RetentionSection from "../retention/section";
import RecordsRequestSection from "../records-request/section";

/**
 * Admin → Documents.
 *
 * What arrives, what is kept, and what goes out: the document inbox (every
 * role reviews it), then - for Admin - how long records are kept and the
 * requests for a person's file. Reading an authorization PDF is linked from
 * here for the roles that can. These were the Document inbox, Retention and
 * Records requests screens; the old paths redirect here.
 *
 * Warrant review is not here: it is money, and lives on Billing → Invoices.
 */
export default async function DocumentsPage() {
  const me = await requireStaff();
  const isAdmin = me.role === "Admin";
  const canReadPdf = CAN_EDIT_BILLING.includes(me.role);

  return (
    <>
      {(isAdmin || canReadPdf) && (
        <nav className="row2 no-print" aria-label="On this page" style={{ gap: 16, marginBottom: 12, fontSize: 13 }}>
          <a href="#inbox">Document inbox</a>
          {isAdmin && <a href="#retention">Retention</a>}
          {isAdmin && <a href="#records-requests">Records requests</a>}
          {canReadPdf && <Link href="/billing/import">Read an authorization PDF</Link>}
        </nav>
      )}

      <section id="inbox">
        <InboxSection />
      </section>

      {isAdmin && (
        <section id="retention" style={{ marginTop: 40, paddingTop: 24, borderTop: "1px solid var(--line)" }}>
          <RetentionSection />
        </section>
      )}

      {isAdmin && (
        <section id="records-requests" style={{ marginTop: 40, paddingTop: 24, borderTop: "1px solid var(--line)" }}>
          <RecordsRequestSection />
        </section>
      )}
    </>
  );
}
