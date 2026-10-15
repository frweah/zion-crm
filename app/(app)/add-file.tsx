"use client";

import { useState, useRef } from "react";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { recordAttachment, type FileState } from "./clients/[id]/files/actions";
import { today } from "@/lib/constants";

const initial: FileState = { error: null, ok: null };
const MAX_BYTES = 52428800;

/** A type of document, as client_file_categories has it (0203). */
export type FileCategory = { key: string; label: string; restricted_by_default: boolean };

function fileSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

/**
 * Add a file to a client's record.
 *
 * One component, used on the client's Documents tab and from the "+" in the
 * header - the owner asked for the same control in both, and two copies of an
 * upload form is two places for the fingerprint, the size limit and the
 * restricted rule to drift apart.
 *
 * The bytes go straight from the browser to storage rather than through a
 * server action: a 50 MB scan has no business passing through one, and the
 * storage policies check the uploader just as well. Only the row is recorded
 * through the server, once the file is safely up.
 *
 * The only difference between the two callers is where clientId comes from:
 * the record already knows, and the "+" asks first.
 */
export function AddFileForm({
  clientId,
  canSeeRestricted,
  categories,
  onAdded,
  restrictedNote,
}: {
  clientId: string;
  canSeeRestricted: boolean;
  /** The types, from the database. Nothing here keeps a second copy. */
  categories: FileCategory[];
  /** The list below refreshes itself; the modal closes. */
  onAdded?: () => void;
  /**
   * Why the restricted box is off, when it is off for a reason other than
   * this person not being allowed. The "+" in the header does not know which
   * clients they may restrict for, so it says where to do it instead of
   * claiming they cannot.
   */
  restrictedNote?: string;
}) {
  const router = useRouter();
  const formRef = useRef<HTMLFormElement>(null);
  const [uploading, setUploading] = useState(false);
  const [message, setMessage] = useState<{ error?: string; ok?: string } | null>(null);

  /**
   * The Restricted switch follows the type, until somebody moves it.
   *
   * An ID, a diagnosis, a court order or a client's bank letter starts
   * restricted (0203) - the owner's point being that the moment to decide is
   * not after the scan is already on the record for everybody. Choosing a
   * different type sets the switch to that type's default again; touching the
   * switch itself stops that, because at that point the person has said what
   * they want and the form should stop arguing.
   *
   * It is a default and not a rule. Turning it off is allowed, and the
   * database writes down that somebody did.
   */
  const [category, setCategory] = useState(categories[0]?.key ?? "Other");
  const [restricted, setRestricted] = useState(categories[0]?.restricted_by_default ?? false);
  const [decided, setDecided] = useState(false);

  const sensitive = categories.find((c) => c.key === category)?.restricted_by_default ?? false;

  function chooseCategory(key: string) {
    setCategory(key);
    if (!decided) setRestricted(categories.find((c) => c.key === key)?.restricted_by_default ?? false);
  }

  /**
   * The file's own fingerprint, so one client cannot hold the same bytes
   * twice (0202). Computed here because this is where the bytes already are -
   * sending 50 MB to a server action to hash it would be the thing the
   * browser-direct upload exists to avoid.
   */
  async function fingerprint(file: File): Promise<string> {
    try {
      const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
      return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
    } catch {
      // No subtle crypto (an insecure origin, an old browser): the upload is
      // worth more than the dedupe, so it goes up without one.
      return "";
    }
  }

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
      meta.set("mime_type", file.type);
      meta.set("size_bytes", String(file.size));
      meta.set("category", String(formData.get("category") ?? "Other"));
      meta.set("note", String(formData.get("note") ?? ""));
      // The name a person typed, falling back to what their machine called it.
      meta.set("filename", String(formData.get("name") ?? "").trim() || file.name);
      meta.set("document_date", String(formData.get("document_date") ?? ""));
      meta.set("sha256", await fingerprint(file));
      if (formData.get("restricted")) meta.set("restricted", "on");

      const result = await recordAttachment(initial, meta);
      if (result.error) {
        setMessage({ error: result.error });
      } else {
        setMessage({ ok: result.ok ?? "Attached." });
        formRef.current?.reset();
        router.refresh();
        onAdded?.();
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
      <div className="card" style={{ marginBottom: 14 }}>
        <h3>Add a file</h3>
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
            <label className="field" style={{ flex: 2 }}>
              Name
              <input name="name" placeholder="Left blank, the file keeps its own name" />
            </label>
            <label className="field">
              Date on the document
              <input name="document_date" type="date" defaultValue={today()} />
            </label>
            <label className="field">
              What it is
              <select name="category" value={category} onChange={(e) => chooseCategory(e.target.value)}>
                {categories.map((c) => (
                  <option key={c.key} value={c.key}>
                    {c.label}
                  </option>
                ))}
              </select>
            </label>
            <label className="field" style={{ flex: 2 }}>
              Note (optional)
              <input name="note" placeholder="e.g. USOR 95 work schedule, August" />
            </label>
          </div>

          <div className="row2" style={{ marginTop: 10, alignItems: "center" }}>
            <label style={{ fontSize: "var(--text-md)" }}>
              <input
                type="checkbox"
                name="restricted"
                style={{ width: "auto", marginRight: 8 }}
                checked={restricted && canSeeRestricted}
                disabled={!canSeeRestricted}
                onChange={(e) => {
                  setRestricted(e.target.checked);
                  setDecided(true);
                }}
              />
              Restricted — limit to Admin, Intake &amp; Client Reports, and the assigned staff member
            </label>
            <button className="btn gold" type="submit" disabled={uploading}>
              {uploading ? "Uploading…" : "Attach"}
            </button>
          </div>

          {/* Said where the decision is being made, not in the paragraph
              underneath: somebody turning this off for an ID should see what
              it means while their hand is on it. */}
          {sensitive && canSeeRestricted && !restricted && (
            <p className="alert" style={{ marginTop: 10 }}>
              A {(categories.find((c) => c.key === category)?.label ?? category).toLowerCase()} is
              restricted unless you say otherwise. Leaving this off puts it in front of everybody
              who can open this client, and is recorded against your name.
            </p>
          )}

          <p className="lock" style={{ margin: "10px 0 0" }}>
            Up to 50 MB. PDFs, images, Word, Excel and text files. The upload date is recorded by
            itself; the date above is the date on the paper. An ID, anything medical, a
            guardianship or legal paper and the client&rsquo;s own financial documents start
            restricted; anything else carrying disability or intake detail should be ticked.
            {!canSeeRestricted &&
              (restrictedNote ??
                " You cannot add restricted documents for this client, so that box is disabled.")}
          </p>
        </form>
      </div>
  );
}
