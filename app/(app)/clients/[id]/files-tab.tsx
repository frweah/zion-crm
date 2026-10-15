"use client";

import { useState, useActionState } from "react";
import {
  getDownloadUrl,
  deleteAttachment,
  editAttachment,
  type FileState,
} from "./files/actions";
import { fmtStamp } from "@/lib/constants";
import { AddFileForm, type FileCategory } from "../../add-file";
import { DataTable } from "../../data-table";

const initial: FileState = { error: null, ok: null };

/**
 * A row of client_documents (0202), not of attachments.
 *
 * The difference matters: a restricted document somebody may not open still
 * comes back, with its name, note, type and path blank and can_open false, so
 * the list can say that a file is there without saying what it is.
 */
export type AttachmentRow = {
  id: string;
  storage_path: string;
  filename: string;
  mime_type: string;
  size_bytes: number | null;
  category: string;
  restricted: boolean;
  note: string;
  uploaded_by: string | null;
  uploaded_by_name: string;
  created_at: string;
  document_date: string;
  can_open: boolean;
};

function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/**
 * Open and Remove for one file: the only part of a file's row that acts, so it
 * is its own cell rather than the whole row being a component.
 */
/**
 * Correcting the name or the date, in the row itself.
 *
 * Behind a button, because the common act is reading the list rather than
 * fixing it. The upload date is not here: that is a fact about this system
 * and nobody gets to edit it.
 */
function EditFile({ clientId, file }: { clientId: string; file: AttachmentRow }) {
  const [state, action, saving] = useActionState(editAttachment, initial);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button className="btn ghost" type="button" style={{ padding: "2px 10px" }} onClick={() => setOpen(true)}>
        Rename
      </button>
    );
  }
  return (
    <form action={action} style={{ display: "inline-flex", gap: 4, alignItems: "center" }}>
      <input type="hidden" name="attachment_id" value={file.id} />
      <input type="hidden" name="client_id" value={clientId} />
      <input name="filename" defaultValue={file.filename} aria-label="The document's name" required />
      <input
        name="document_date"
        type="date"
        defaultValue={file.document_date}
        aria-label="The date on the document"
        required
      />
      <button className="btn" type="submit" disabled={saving} style={{ padding: "2px 10px" }}>
        {saving ? "…" : "Save"}
      </button>
      <button className="btn ghost" type="button" style={{ padding: "2px 10px" }} onClick={() => setOpen(false)}>
        Cancel
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}

function FileActions({ clientId, file }: { clientId: string; file: AttachmentRow }) {
  const [openState, openAction, opening] = useActionState(getDownloadUrl, initial);
  const [delState, delAction, deleting] = useActionState(deleteAttachment, initial);

  // The signed link is deliberately short-lived, so it is opened as soon as it
  // comes back rather than left sitting on the page.
  if (openState.url) {
    window.open(openState.url, "_blank", "noopener");
    openState.url = undefined;
  }

  return (
    <div style={{ textAlign: "right", whiteSpace: "nowrap" }}>
        <form action={openAction} style={{ display: "inline" }}>
          <input type="hidden" name="storage_path" value={file.storage_path} />
          <button className="btn ghost" type="submit" disabled={opening}>
            {opening ? "…" : "Open"}
          </button>
        </form>{" "}
        <EditFile clientId={clientId} file={file} />{" "}
        <form action={delAction} style={{ display: "inline" }}>
          <input type="hidden" name="attachment_id" value={file.id} />
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" type="submit" disabled={deleting}>
            {deleting ? "…" : "Remove"}
          </button>
        </form>
        {(openState.error || delState.error) && (
          <div style={{ color: "var(--bad)", fontSize: "var(--text-sm)", whiteSpace: "normal" }}>
            {openState.error ?? delState.error}
          </div>
        )}
    </div>
  );
}

export function FilesTab({
  clientId,
  files,
  canSeeRestricted,
  categories,
}: {
  clientId: string;
  files: AttachmentRow[];
  canSeeRestricted: boolean;
  categories: FileCategory[];
}) {
  return (
    <>
      <AddFileForm
        clientId={clientId}
        canSeeRestricted={canSeeRestricted}
        categories={categories}
      />
      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="documents"
          columns={[
            { key: "name", label: "Name" },
            { key: "date", label: "Document date" },
            { key: "category", label: "Type" },
            { key: "who", label: "Uploaded by" },
            { key: "actions", label: "", sortable: false },
          ]}
          rows={files.map((f) => ({
            key: f.id,
            sort: {
              name: f.filename,
              date: f.document_date,
              category: f.category,
              who: f.uploaded_by_name,
            },
            text: [f.filename, f.category, f.note, f.uploaded_by_name, f.restricted ? "restricted" : ""]
              .filter(Boolean)
              .join(" "),
            cells: {
              /**
               * A document somebody may not open is still a row.
               *
               * Until today it was filtered out entirely and the client record
               * said so on purpose. The owner reversed that on 15 Oct 2026:
               * a colleague who can see that a file is there asks about it
               * instead of uploading a second copy. What they get is that it
               * exists and nothing else - the view blanks the name, the note
               * and the type before this component ever sees them.
               */
              name: f.can_open ? (
                <>
                  <b>{f.filename}</b>
                  {f.restricted && (
                    <span className="chip warn" style={{ marginLeft: 6 }}>
                      restricted
                    </span>
                  )}
                  {f.note && <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>{f.note}</div>}
                  {f.size_bytes ? (
                    <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>{fileSize(f.size_bytes)}</div>
                  ) : null}
                </>
              ) : (
                <>
                  <b className="lock">A restricted document</b>
                  <span className="chip warn" style={{ marginLeft: 6 }}>
                    restricted
                  </span>
                  <div style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
                    Admin, Intake &amp; Client Reports and this client&rsquo;s assigned staff can open it.
                  </div>
                </>
              ),
              date: <span style={{ whiteSpace: "nowrap" }}>{f.document_date}</span>,
              category: f.can_open ? <span className="chip">{f.category}</span> : <span className="lock">—</span>,
              who: (
                <span style={{ fontSize: "var(--text-sm)", color: "var(--muted)" }}>
                  {f.uploaded_by_name}
                  <div>uploaded {fmtStamp(f.created_at)}</div>
                </span>
              ),
              actions: f.can_open ? <FileActions clientId={clientId} file={f} /> : <span className="lock">—</span>,
            },
          }))}
          empty="No documents yet. Signed USOR forms, work schedules, authorizations and employer verifications belong here rather than in a Downloads folder."
        />
      </div>
    </>
  );
}
