import Link from "next/link";
import { can } from "@/lib/roles";
import { requireStaff } from "@/lib/session";
import { PageHead } from "../../page-head";
import InboxSection from "../inbox/section";
import { AgentStatus } from "../inbox/agent-status";

/**
 * Billing → Documents.
 *
 * What has arrived from the client folders and is waiting for somebody to say
 * what it is (every role reviews it), and - for Billing - whether the
 * documents agent on the office PC is running. Both were under Admin until
 * Admin became Admin's alone (owner, 19 Sept 2026); the old paths redirect.
 */
export default async function BillingDocumentsPage() {
  const me = await requireStaff();
  const canReadPdf = can(me, "billing", "edit");
  const seesAgent = can(me, "billing", "view");

  const toc: [string, string][] = [["inbox", "Document inbox"]];
  if (seesAgent) toc.push(["agent", "Documents agent"]);

  return (
    <>
      <PageHead
        title="Documents"
        context="What has arrived from the client folders and is waiting for somebody to say what it is"
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

      {seesAgent && (
        <section id="agent" className="page-section">
          <h2 className="h2">Documents agent</h2>
          <p className="sub">
            The program on the office PC that reads the client folders and posts what it finds to the inbox above. It
            runs every fifteen minutes when the machine is on.
          </p>
          <AgentStatus />
        </section>
      )}
    </>
  );
}
