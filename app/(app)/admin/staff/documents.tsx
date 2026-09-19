"use client";

import { useActionState, useEffect, useState } from "react";
import {
  uploadStaffDocument,
  openStaffDocument,
  deleteStaffDocument,
  recordInspection,
  type DocumentState,
} from "./document-actions";
import { DataTable } from "../../data-table";

const initial: DocumentState = { error: null, ok: null };

export type DocCategory = {
  key: string;
  label: string;
  detail: string;
  system_only: boolean;
};

export type DocRow = {
  id: string;
  staff_id: string;
  filename: string;
  category: string;
  category_label: string;
  system_generated: boolean;
  note: string;
  size_bytes: number;
  created_at: string;
  uploaded_by_name: string | null;
  backs_a_credential: boolean;
  inspection_required?: boolean;
  inspected_at?: string | null;
  inspected_by_name?: string | null;
};

/** Admin, originals in hand: the one thing that clears an I-9 document. */
function InspectButton({ id }: { id: string }) {
  const [state, action, pending] = useActionState(recordInspection, initial);
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="file_id" value={id} />
      <button className="btn gold" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Inspected in person"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

const size = (bytes: number) =>
  bytes >= 1024 * 1024 ? `${(bytes / 1024 / 1024).toFixed(1)} MB` : `${Math.round(bytes / 1024)} KB`;

/** Opens in a new tab as soon as the short-lived link arrives. */
export function OpenButton({ id }: { id: string }) {
  const [state, action, pending] = useActionState(openStaffDocument, initial);

  useEffect(() => {
    if (state.url) window.open(state.url, "_blank", "noopener");
  }, [state.url]);

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="file_id" value={id} />
      <button className="btn ghost" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Open"}
      </button>
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

function DeleteButton({ doc }: { doc: DocRow }) {
  const [state, action, pending] = useActionState(deleteStaffDocument, initial);
  const [sure, setSure] = useState(false);

  if (!sure) {
    return (
      <button
        className="btn ghost"
        type="button"
        onClick={() => setSure(true)}
        style={{ padding: "2px 10px" }}
      >
        Remove
      </button>
    );
  }

  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="file_id" value={doc.id} />
      <button className="btn" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Really remove"}
      </button>
      <button
        className="btn ghost"
        type="button"
        onClick={() => setSure(false)}
        style={{ padding: "2px 10px", marginLeft: 4 }}
      >
        Keep
      </button>
      {doc.backs_a_credential && (
        <div style={{ color: "var(--bad)", fontSize: 12 }}>
          A credential is relying on this — removing it leaves that unevidenced.
        </div>
      )}
      {state.error && <div style={{ color: "var(--bad)", fontSize: 12 }}>{state.error}</div>}
    </form>
  );
}

/**
 * Somebody's documents.
 *
 * The same component serves a person looking at their own file and Admin
 * looking at anybody's — the difference is what the database allows, not what
 * is drawn, so there is only one of these to keep right.
 */
export function StaffDocuments({
  staffId,
  staffName,
  docs,
  categories,
  canDelete,
  compact,
  readOnly,
}: {
  staffId: string;
  staffName?: string;
  docs: DocRow[];
  categories: DocCategory[];
  canDelete: boolean;
  compact?: boolean;
  /** Somebody inactive: every document can be opened, and none added or removed. */
  readOnly?: boolean;
}) {
  const [state, action, pending] = useActionState(uploadStaffDocument, initial);
  const [adding, setAdding] = useState(false);

  const uploadable = categories.filter((c) => !c.system_only);

  return (
    <div className="card" style={{ marginTop: 14, marginBottom: compact ? 0 : 14 }}>
      <div className="row2" style={{ justifyContent: "space-between", alignItems: "flex-start" }}>
        <div>
          <h3 style={{ margin: 0 }}>{staffName ? `${staffName} — documents` : "Your documents"}</h3>
          <p className="sub" style={{ margin: "4px 0 0" }}>
            Held privately — you and the administrator, nobody else.
          </p>
        </div>
        {!readOnly && (
          <button className="btn" type="button" onClick={() => setAdding(!adding)}>
            {adding ? "Cancel" : "Add a document"}
          </button>
        )}
      </div>

      {state.error && <div className="alert bad" style={{ marginTop: 10 }}>{state.error}</div>}
      {state.ok && <div className="alert ok" style={{ marginTop: 10 }}>{state.ok}</div>}

      {adding && (
        <form action={action} style={{ marginTop: 10 }}>
          <input type="hidden" name="staff_id" value={staffId} />
          <div className="row2">
            <label className="field" style={{ maxWidth: 220 }}>
              What is it
              <select name="category" required defaultValue="">
                <option value="">Choose…</option>
                {uploadable.map((c) => (
                  <option key={c.key} value={c.key}>
                    {c.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              File
              <input
                type="file"
                name="file"
                required
                accept=".pdf,.jpg,.jpeg,.png,.heic,.webp,.doc,.docx"
              />
            </label>
            <label className="field" style={{ flex: 2 }}>
              Note
              <input name="note" placeholder="Anything worth saying about it" />
            </label>
            <button className="btn gold" type="submit" disabled={pending}>
              {pending ? "Uploading…" : "Add it"}
            </button>
          </div>
          <p className="lock" style={{ margin: "8px 0 0" }}>
            A PDF, a photograph or a Word document, up to 25MB. Tax forms are signed in the app
            rather than uploaded, so they are not on this list.
          </p>
        </form>
      )}

      <div style={{ marginTop: 10, border: "1px solid var(--line)", borderRadius: 6 }}>
        <DataTable
          label="documents"
          columns={[
            { key: "category", label: "What it is" },
            { key: "file", label: "File" },
            { key: "added", label: "Added" },
            { key: "actions", label: "", sortable: false },
          ]}
          rows={docs.map((d) => ({
            key: d.id,
            text: `${d.category_label} ${d.filename} ${d.note} ${d.uploaded_by_name ?? ""}`,
            sort: { category: d.category_label, file: d.filename, added: d.created_at },
            cells: {
              category: (
                <>
                  {d.category_label}
                  {d.backs_a_credential && <div className="lock">evidence for a credential</div>}
                  {d.inspection_required && (
                    <div>
                      <span className="chip warn">In-person inspection still required</span>
                    </div>
                  )}
                  {d.category === "I-9" && d.inspected_at && (
                    <div className="lock">
                      inspected in person {d.inspected_at.slice(0, 10)}
                      {d.inspected_by_name ? ` by ${d.inspected_by_name}` : ""}
                    </div>
                  )}
                </>
              ),
              file: (
                <>
                  {d.filename}
                  <div className="lock">
                    {size(d.size_bytes)}
                    {d.uploaded_by_name && ` · added by ${d.uploaded_by_name}`}
                    {d.system_generated && " · signed in the app"}
                  </div>
                  {d.note && <div style={{ fontSize: 12 }}>{d.note}</div>}
                </>
              ),
              added: d.created_at.slice(0, 10),
              actions: (
                <span style={{ whiteSpace: "nowrap" }}>
                  <OpenButton id={d.id} />
                  {canDelete && !readOnly && d.inspection_required && (
                    <span style={{ marginLeft: 4 }}>
                      <InspectButton id={d.id} />
                    </span>
                  )}
                  {canDelete && !readOnly && !d.system_generated && (
                    <span style={{ marginLeft: 4 }}>
                      <DeleteButton doc={d} />
                    </span>
                  )}
                </span>
              ),
            },
          }))}
          empty="Nothing is on file yet."
        />
      </div>

      <p className="lock" style={{ margin: "10px 0 0" }}>
        Opening somebody else&apos;s document is recorded in the access log. Opening your own is
        not — the log answers who else has been through a personnel file.
      </p>
    </div>
  );
}
