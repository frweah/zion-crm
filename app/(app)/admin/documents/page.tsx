import { requireAdmin } from "@/lib/session";
import { PageHead } from "../../page-head";
import RetentionSection from "../retention/section";
import RecordsRequestSection from "../records-request/section";

/**
 * Admin → Documents.
 *
 * How long records are kept, and requests for a person's file - Admin's
 * alone. The document inbox that used to open this page is Billing →
 * Documents now (owner, 19 Sept 2026), with the documents agent's status.
 */
export default async function DocumentsPage() {
  await requireAdmin();

  return (
    <>
      <PageHead
        title="Documents"
        context="How long records are kept, and requests for a person's file"
        toc={[
          ["retention", "Retention"],
          ["records-requests", "Records requests"],
        ]}
      />

      <section id="retention" className="page-section">
        <RetentionSection />
      </section>

      <section id="records-requests" className="page-section">
        <RecordsRequestSection />
      </section>
    </>
  );
}
