import Link from "next/link";
import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../page-head";
import InboxSection from "../inbox/section";
import RetentionSection from "../retention/section";
import RecordsRequestSection from "../records-request/section";

/**
 * Admin → Documents, Admin's alone (owner, 19 Sept 2026).
 *
 * What arrives, what is kept, and what goes out: the document inbox - folders
 * nobody has claimed, warrant stubs, invoices, USOR forms, anything unreadable
 * - then how long records are kept and the requests for a person's file.
 * Billing confirms the authorizations from the inbox on Billing →
 * Authorizations, where the documents agent's status is too.
 */
export default async function DocumentsPage() {
  await requireAdmin();

  return (
    <>
      <PageHead
        title="Documents"
        context="What has arrived and is waiting, how long records are kept, and requests for a person's file"
        actions={
          <Link className="btn ghost" href="/billing/import" style={{ textDecoration: "none" }}>
            Read an authorization PDF
          </Link>
        }
        toc={[
          ["inbox", "Document inbox"],
          ["retention", "Retention"],
          ["records-requests", "Records requests"],
        ]}
      />

      <section id="inbox" className="page-section">
        <InboxSection />
      </section>

      <section id="retention" className="page-section">
        <RetentionSection />
      </section>

      <section id="records-requests" className="page-section">
        <RecordsRequestSection />
      </section>
    </>
  );
}
