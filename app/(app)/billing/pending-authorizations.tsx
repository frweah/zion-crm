import Link from "next/link";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { fmtStamp } from "@/lib/constants";
import { INBOX_BUCKET } from "@/lib/inbox-storage";
import { DataTable } from "../data-table";
import { AuthorizationProposal, type PendingRow, type Placeholder } from "../admin/inbox/inbox-view";
import { WhoseDocument } from "../admin/inbox/whose-document";
import { AgentStatus } from "../admin/inbox/agent-status";
import { PdfFrame } from "./pdf-frame";

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
  openAdd = false,
  children,
}: {
  /** The read-it-off-the-PDF form, which lives inside this panel (A5). */
  children?: React.ReactNode;
  selected: string | null;
  /** Add authorization was followed, so the panel opens on an empty queue. */
  openAdd?: boolean;
  /** The Authorizations tab's own address with ?doc= set, keeping its filters. */
  hrefFor: (docId: string | null) => string;
}) {
  const supabase = await createClient();
  const [
    { data: pendingRows },
    { data: placeholderRows },
    { data: clientRows },
    { data: counselorRows },
    { data: officeRows },
  ] = await Promise.all([
    supabase.from("inbox_pending").select("*").order("first_seen", { ascending: false }),
    supabase
      .from("authorizations")
      .select("id, client_id, number, service_type, carried_used, total_hours")
      // Whatever an authorization without a USOR number looks like this year
      // (0251). It was `.like("number", "(workbook)%")`, which was the
      // spreadsheet import's own label and has not matched a row since every
      // one of those was given its real number - so this list was empty and
      // "Replace with this number" was never offered for the authorizations
      // that actually need it.
      .eq("has_usor_number", false),
    // Whose a queued PDF is, chosen here rather than waited for (owner,
    // 19 November 2026). The same three lists Admin → Documents hands its own
    // picker, because it is the same picker: a second one would be a second
    // set of rules about who may be chosen.
    supabase.from("clients").select("id, name").order("name"),
    supabase.from("counselors").select("id, name").order("name"),
    supabase.from("offices").select("name").order("name"),
  ]);

  const pending = ((pendingRows ?? []) as unknown as PendingRow[]).filter(isAuthorization);
  const placeholders = (placeholderRows ?? []) as unknown as Placeholder[];
  const clients = clientRows ?? [];
  const counselors = counselorRows ?? [];
  const offices = (officeRows ?? []).map((o) => o.name);
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
    /*
     * One collapsible panel, below the board since 18 November 2026 (owner):
     * the queue, the PDF beside what was read from it, and the form that reads
     * an authorization off a PDF, which arrives as `children` from the page.
     *
     * Open when the queue has something in it, collapsed when it does not.
     * Work that is waiting is never hidden; an empty queue is not work, and it
     * was taking the top of the screen on the days there was nothing in it.
     *
     * `open` rather than `defaultOpen`: this is a server component, the panel
     * is plain HTML, and the attribute is the state the page is served in.
     * Somebody who opens or closes it keeps that until the page is loaded
     * again, which is the whole of what a `details` remembers.
     */
    <details
      id="from-documents"
      className="page-section"
      open={pending.length > 0 || openAdd}
      style={{ marginBottom: 24 }}
    >
      <summary className="h2" style={{ cursor: "pointer" }}>
        From the documents folder ({pending.length})
      </summary>
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
            {storagePath ? (
              // Keyed by the document so opening another starts the viewer afresh.
              <PdfFrame key={doc.id} docId={doc.id} initialUrl={pdfUrl} title={`The PDF: ${doc.filename}`} />
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
            {/*
              Whose it is, then what it is (owner, 19 November 2026).
              Billing waited for Admin to say whose a folder was - "Once the
              administrator has said whose it is, it can be confirmed here" -
              which meant a PDF in front of somebody who could read the name
              off it and could do nothing with it. The picker is the one
              Admin → Documents uses, and `assign_document_to_client` has
              allowed Billing since it was written.
            */}
            <WhoseDocument
              docId={doc.id}
              parsed={(doc.parsed ?? {}) as Record<string, unknown>}
              clients={clients}
              counselors={counselors}
              offices={offices}
              current={doc.client_id}
            />
            <AuthorizationProposal
              doc={doc}
              canBill
              placeholders={placeholders}
              clientChosen={Boolean(doc.client_id)}
            />
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

      {children}

      <details id="agent" style={{ marginTop: 12 }}>
        <summary style={{ cursor: "pointer" }}>Is the documents agent running?</summary>
        <div style={{ marginTop: 10 }}>
          <AgentStatus />
        </div>
      </details>
    </details>
  );
}
