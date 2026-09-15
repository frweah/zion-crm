"use client";

import { useState, useRef, useActionState } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import {
  recordAttachment,
  getDownloadUrl,
  deleteAttachment,
  type FileState,
} from "./files/actions";
import { fmtStamp } from "@/lib/constants";
import { DataTable } from "../../data-table";

const initial: FileState = { error: null, ok: null };

const CATEGORIES = [
  "Signed USOR form",
  "Work schedule",
  "Authorization",
  "Signed intake",
  "Employer verification",
  "Invoice",
  "Guardianship document",
  "Other",
];

const MAX_BYTES = 52428800;

export type AttachmentRow = {
  id: string;
  storage_path: string;
  filename: string;
  mime_type: string;
  size_bytes: number;
  category: string;
  restricted: boolean;
  note: string;
  uploaded_by_name: string;
  created_at: string;
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
        <form action={delAction} style={{ display: "inline" }}>
          <input type="hidden" name="attachment_id" value={file.id} />
          <input type="hidden" name="client_id" value={clientId} />
          <button className="btn ghost" type="submit" disabled={deleting}>
            {deleting ? "…" : "Remove"}
          </button>
        </form>
        {(openState.error || delState.error) && (
          <div style={{ color: "var(--bad)", fontSize: 12, whiteSpace: "normal" }}>
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
}: {
  clientId: string;
  files: AttachmentRow[];
  canSeeRestricted: boolean;
}) {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  const [uploading, setUploading] = useState(false);
  const [message, setMessage] = useState<{ error?: string; ok?: string } | null>(null);

  async function upload(formData: FormData) {
    const file = formData.get("file") as File | null;
    if (!file || file.size === 0) {
      setMessage({ error: "Choose a file first." });
      return;
    }
    if (file.size > MAX_BYTES) {
      setMessage({
        error: `${file.name} is ${fileSize(file.size)}. The limit is 50 MB — scan at a lower resolution or split it.`,
      });
      return;
    }

    setUploading(true);
    setMessage(null);

    try {
      const supabase = createClient();
      const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
      const path = `clients/${clientId}/${crypto.randomUUID()}${ext ? `.${ext}` : ""}`;

      const { error } = await supabase.storage
        .from("client-files")
        .upload(path, file, { contentType: file.type || "application/octet-stream" });

      if (error) {
        setMessage({
          error:
            error.message.toLowerCase().includes("mime") ||
            error.message.toLowerCase().includes("type")
              ? `${file.name} is not an accepted file type. PDFs, images, Word, Excel and text files are allowed.`
              : `Upload failed: ${error.message}`,
        });
        setUploading(false);
        return;
      }

      const meta = new FormData();
      meta.set("client_id", clientId);
      meta.set("storage_path", path);
      meta.set("filename", file.name);
      meta.set("mime_type", file.type);
      meta.set("size_bytes", String(file.size));
      meta.set("category", String(formData.get("category") ?? "Other"));
      meta.set("note", String(formData.get("note") ?? ""));
      if (formData.get("restricted")) meta.set("restricted", "on");

      const result = await recordAttachment(initial, meta);
      if (result.error) {
        setMessage({ error: result.error });
      } else {
        setMessage({ ok: result.ok ?? "Attached." });
        formRef.current?.reset();
        router.refresh();
      }
    } catch (err) {
      setMessage({
        error: `Upload failed: ${err instanceof Error ? err.message : "unknown error"}`,
      });
    } finally {
      setUploading(false);
    }
  }

  return (
    <>
      <div className="card" style={{ marginBottom: 14 }}>
        <h3>Attach a document</h3>
        {message?.error && <div className="alert bad">{message.error}</div>}
        {message?.ok && <div className="alert ok">{message.ok}</div>}

        <form ref={formRef} action={upload}>
          <div className="row2">
            <label className="field" style={{ flex: 2 }}>
              File
              <input
                name="file"
                type="file"
                accept=".pdf,.jpg,.jpeg,.png,.heic,.webp,.tif,.tiff,.doc,.docx,.xls,.xlsx,.txt,.csv"
                required
              />
            </label>
            <label className="field">
              What it is
              <select name="category" defaultValue="Signed USOR form">
                {CATEGORIES.map((c) => (
                  <option key={c}>{c}</option>
                ))}
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Note (optional)
              <input name="note" placeholder="e.g. USOR 95 work schedule, August" />
            </label>
          </div>

          <div className="row2" style={{ marginTop: 10, alignItems: "center" }}>
            <label style={{ fontSize: 13 }}>
              <input
                type="checkbox"
                name="restricted"
                style={{ width: "auto", marginRight: 8 }}
                disabled={!canSeeRestricted}
              />
              Restricted — limit to Admin, Intake &amp; Client Reports, and the assigned staff member
            </label>
            <button className="btn gold" type="submit" disabled={uploading}>
              {uploading ? "Uploading…" : "Attach"}
            </button>
          </div>

          <p className="lock" style={{ margin: "10px 0 0" }}>
            Up to 50 MB. PDFs, images, Word, Excel and text files. Tick restricted for anything
            carrying disability, medical or intake detail — a signed intake or a USOR 94.
            {!canSeeRestricted &&
              " You cannot add restricted documents for this client, so that box is disabled."}
          </p>
        </form>
      </div>

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="files"
          columns={[
            { key: "file", label: "File" },
            { key: "category", label: "Type" },
            { key: "size", label: "Size", align: "right" },
            { key: "added", label: "Added" },
            { key: "actions", label: "", sortable: false },
          ]}
          rows={files.map((f) => ({
            key: f.id,
            sort: {
              file: f.filename,
              category: f.category,
              size: f.size_bytes,
              added: f.created_at,
            },
            text: [f.filename, f.category, f.note, f.uploaded_by_name, f.restricted ? "restricted" : ""].join(" "),
            cells: {
              file: (
                <>
                  <b>{f.filename}</b>
                  {f.restricted && (
                    <span className="chip warn" style={{ marginLeft: 6 }}>
                      restricted
                    </span>
                  )}
                  {f.note && <div style={{ fontSize: 12, color: "var(--muted)" }}>{f.note}</div>}
                </>
              ),
              category: <span className="chip">{f.category}</span>,
              size: (
                <span style={{ fontSize: 12, color: "var(--muted)", whiteSpace: "nowrap" }}>
                  {fileSize(f.size_bytes)}
                </span>
              ),
              added: (
                <span style={{ fontSize: 12, color: "var(--muted)" }}>
                  {f.uploaded_by_name}
                  <div>{fmtStamp(f.created_at)}</div>
                </span>
              ),
              actions: <FileActions clientId={clientId} file={f} />,
            },
          }))}
          empty="No documents yet. Signed USOR forms, work schedules, authorizations and employer verifications belong here rather than in a Downloads folder."
        />
      </div>
    </>
  );
}
