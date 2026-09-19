import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtStamp } from "@/lib/constants";
import { INBOX_BUCKET } from "@/lib/inbox-storage";
import { DataTable } from "../data-table";
import { AuthorizationProposal, type PendingRow, type Placeholder } from "../admin/inbox/inbox-view";
import { AgentStatus } from "../admin/inbox/agent-status";

/**
 * Authorizations from the documents folder, confirmed by Billing here rather
 * than in the Admin inbox (owner, 19 Sept 2026).
 *
 * The same pick-and-confirm the inbox uses, one document at a time with its
 * PDF beside it. Only authorizations reach this list: the database shows
 * Billing those and nothing else from the inbox (0103), so the list is what
 * the rules allow rather than what this screen chooses to draw. Folders
 * nobody has claimed, warrant stubs and everything else stay in Admin →
 * Documents.
 */
const isAuthorization = (d: PendingRow) =>
  d.kind === "Authorization" ||
  ((d.proposal ?? {}) as { filename?: { named?: string } }).filename?.named === "Authorization";

export default async function PendingAuthorizations({
  selected,
  hrefFor,
}: {
  selected: string | null;
  /** The Authorizations tab's own address with ?doc= set, keeping its filters. */
  hrefFor: (docId: string | null) => string;
}) {
  const supabase = await createClient();
  const [{ data: pendingRows }, { data: placeholderRows }] = await Promise.all([
    supabase.from("inbox_pending").select("*").order("first_seen", { ascending: false }),
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, carried_used, total_hours")
      .like("number", "(workbook)%"),
  ]);

  const pending = ((pendingRows ?? []) as unknown as PendingRow[]).filter(isAuthorization);
  const placeholders = (placeholderRows ?? []) as unknown as Placeholder[];
  const doc = pending.find((d) => d.id === selected) ?? null;

  // The file is minted a short-lived link only for a row the rules above
  // have already shown this person.
  let pdfUrl: string | null = null;
  const storagePath = (doc as unknown as { storage_path?: string | null } | null)?.storage_path;
  if (doc && storagePath) {
    const { data } = await createAdminClient().storage.from(INBOX_BUCKET).createSignedUrl(storagePath, 60 * 15);
    pdfUrl = data?.signedUrl ?? null;
  }

  return (
    <section id="from-documents" className="page-section" style={{ marginTop: 0, marginBottom: 24 }}>
      <h2 className="h2">From the documents folder</h2>
      <p className="sub" style={{ margin: "0 0 10px" }}>
        {pending.length === 0
          ? "No authorization from the client folders is waiting to be confirmed."
          : `${pending.length} authorization${pending.length === 1 ? "" : "s"} read from the client folders, waiting for somebody to say which authorization each is. Open one to see the PDF beside what was read from it.`}
      </p>

      {doc && (
        <div
          className="grid"
          style={{ gridTemplateColumns: "repeat(auto-fit, minmax(360px, 1fr))", alignItems: "start", marginBottom: 14 }}
        >
          <div className="card" style={{ padding: 0, overflow: "hidden" }}>
            {pdfUrl ? (
              <iframe
                src={pdfUrl}
                title={`The PDF: ${doc.filename}`}
                style={{ width: "100%", height: 720, border: 0, display: "block" }}
              />
            ) : (
              <p className="empty" style={{ padding: 20 }}>
                The file could not be opened. It may still be uploading from the office PC.
              </p>
            )}
          </div>
          <div className="card">
            <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
              <div>
                <b>{doc.filename}</b>
                <div className="lock">
                  {doc.client_name ? (
                    <Link href={`/clients/${doc.client_id}`}>{doc.client_name}</Link>
                  ) : (
                    <span style={{ color: "var(--bad)" }}>no client yet - Admin says whose folder it is</span>
                  )}{" "}
                  · seen {fmtStamp(doc.first_seen)}
                </div>
              </div>
              <Link className="btn ghost" href={hrefFor(null)} style={{ textDecoration: "none" }}>
                Close
              </Link>
            </div>
            {doc.client_id ? (
              <AuthorizationProposal doc={doc} canBill placeholders={placeholders} />
            ) : (
              <p className="sub" style={{ marginTop: 10 }}>
                Its folder is not a client yet. Once the administrator has said whose it is, it can be confirmed here.
              </p>
            )}
          </div>
        </div>
      )}

      {pending.length > 0 && (
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="documents"
            pageSize={50}
            columns={[
              { key: "client", label: "Client" },
              { key: "document", label: "Document" },
              { key: "seen", label: "Seen" },
              { key: "open", label: "", sortable: false },
            ]}
            rows={pending.map((d) => ({
              key: d.id,
              cells: {
                client: d.client_name ?? <span className="lock">no client yet</span>,
                document: (
                  <>
                    {d.filename}
                    <div className="lock">{d.folder_name || "(loose in the top folder)"}</div>
                  </>
                ),
                seen: <span style={{ whiteSpace: "nowrap" }}>{fmtStamp(d.first_seen)}</span>,
                open:
                  d.id === selected ? (
                    <span className="chip gold">Open</span>
                  ) : (
                    <Link className="btn ghost" href={hrefFor(d.id)} style={{ textDecoration: "none", padding: "2px 10px" }}>
                      Open
                    </Link>
                  ),
              },
              sort: { client: d.client_name ?? "", document: d.filename, seen: d.first_seen },
              text: `${d.client_name ?? ""} ${d.filename} ${d.folder_name}`,
            }))}
            empty="Nothing waiting."
          />
        </div>
      )}

      <details id="agent" style={{ marginTop: 12 }}>
        <summary style={{ cursor: "pointer" }}>Is the documents agent running?</summary>
        <div style={{ marginTop: 10 }}>
          <AgentStatus />
        </div>
      </details>
    </section>
  );
}
