"use client";

import { useActionState, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { recordAttachment } from "../clients/[id]/files/actions";
import {
  sendChatMessage,
  editMessage,
  removeMessage,
  openChatAttachment,
  addParticipant,
  markRead,
  type ChatState,
  type ChatAttachment,
} from "./actions";

const initial: ChatState = { error: null, ok: null };

export type Person = { id: string; name: string };
/** A document already on a client's record, offered to the composer by reference. */
export type Attachable = { kind: "client_file" | "form"; id: string; name: string; restricted: boolean };

/**
 * The open conversation, kept current: a message arriving in it (the
 * foundation's live delivery, live-messaging.tsx) redraws it, and whatever is
 * shown is marked read.
 */
export function ThreadLive({ conversationId, lastSeq }: { conversationId: string; lastSeq: number }) {
  const router = useRouter();
  const end = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (lastSeq > 0) void markRead(conversationId, lastSeq);
    end.current?.scrollIntoView({ block: "end" });
  }, [conversationId, lastSeq]);

  useEffect(() => {
    const onMessage = (e: Event) => {
      const row = (e as CustomEvent<{ conversation_id: string }>).detail;
      if (row.conversation_id === conversationId) router.refresh();
    };
    window.addEventListener("zion:message", onMessage);
    return () => window.removeEventListener("zion:message", onMessage);
  }, [conversationId, router]);

  return <div ref={end} />;
}

/** The names people were called when they were written to, marked in the text. */
export function MessageText({ body, names }: { body: string; names: string[] }) {
  const parts = useMemo(() => {
    if (names.length === 0) return [body];
    const escaped = names.map((n) => n.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|");
    return body.split(new RegExp(`(@(?:${escaped}))`, "g"));
  }, [body, names]);
  return (
    <>
      {parts.map((part, i) =>
        part.startsWith("@") && names.includes(part.slice(1)) ? (
          <b key={i} className="mention">
            {part}
          </b>
        ) : (
          <span key={i}>{part}</span>
        ),
      )}
    </>
  );
}

/**
 * A document attached to a message. The chat holds a reference, so opening it
 * fetches the file from where it has always been and the storage rules decide
 * - which is why a document can go out of reach after it was attached.
 */
export function AttachmentButton({ attachment }: { attachment: ChatAttachment }) {
  const [state, action, pending] = useActionState(openChatAttachment, initial as ChatState & { url?: string });
  useEffect(() => {
    if (state.url) window.open(state.url, "_blank", "noopener,noreferrer");
  }, [state]);

  if (attachment.kind === "form") {
    return (
      <span className="attach-chip">
        <span aria-hidden="true">▤</span> {attachment.name} <span className="lock">form</span>
      </span>
    );
  }
  return (
    <form action={action} style={{ display: "inline" }}>
      <input type="hidden" name="attachment_id" value={attachment.id} />
      <button className="attach-chip" type="submit" disabled={pending}>
        <span aria-hidden="true">▤</span> {pending ? "Opening…" : attachment.name}
      </button>
      {state.error && <span className="lock"> {state.error}</span>}
    </form>
  );
}

/** Your own message: five minutes to correct it, and yours to take back. */
export function MessageActions({ messageId, body, createdAt }: { messageId: string; body: string; createdAt: string }) {
  const [editing, setEditing] = useState(false);
  const [editState, editAction, saving] = useActionState(editMessage, initial);
  const [removeState, removeAction, removing] = useActionState(removeMessage, initial);
  const router = useRouter();
  const stillEditable = Date.now() - new Date(createdAt).getTime() < 5 * 60 * 1000;

  useEffect(() => {
    if (editState.ok) {
      setEditing(false);
      router.refresh();
    }
  }, [editState, router]);
  useEffect(() => {
    if (removeState.ok) router.refresh();
  }, [removeState, router]);

  if (editing) {
    return (
      <form action={editAction} className="composer" style={{ marginTop: 6 }}>
        {editState.error && <div className="alert bad">{editState.error}</div>}
        <input type="hidden" name="message_id" value={messageId} />
        <label className="field" style={{ margin: 0, flex: 1 }}>
          <span className="sr-only">Correct this message</span>
          <textarea name="body" rows={2} defaultValue={body} maxLength={8000} required />
        </label>
        <button className="btn" type="submit" disabled={saving}>
          {saving ? "Saving…" : "Save"}
        </button>
        <button className="btn ghost" type="button" onClick={() => setEditing(false)}>
          Cancel
        </button>
      </form>
    );
  }

  return (
    <div className="chat-actions">
      {stillEditable && (
        <button type="button" className="linkish" onClick={() => setEditing(true)}>
          Correct
        </button>
      )}
      <form action={removeAction} style={{ display: "inline" }}>
        <input type="hidden" name="message_id" value={messageId} />
        <button type="submit" className="linkish" disabled={removing}>
          {removing ? "Removing…" : "Remove"}
        </button>
      </form>
      {removeState.error && <span className="lock">{removeState.error}</span>}
    </div>
  );
}

/** Somebody else into a group. A direct message stays between the two of you. */
export function AddPerson({ conversationId, candidates }: { conversationId: string; candidates: Person[] }) {
  const [open, setOpen] = useState(false);
  const [state, action, pending] = useActionState(addParticipant, initial);
  const router = useRouter();
  useEffect(() => {
    if (state.ok) {
      setOpen(false);
      router.refresh();
    }
  }, [state, router]);

  if (!open) {
    return (
      <button type="button" className="linkish" onClick={() => setOpen(true)}>
        Add someone
      </button>
    );
  }
  return (
    <form action={action} className="row2" style={{ gap: 6, alignItems: "center" }}>
      <input type="hidden" name="conversation_id" value={conversationId} />
      <label className="sr-only" htmlFor={`add-${conversationId}`}>
        Who to add
      </label>
      <select id={`add-${conversationId}`} name="staff_id" required defaultValue="" style={{ maxWidth: 200 }}>
        <option value="" disabled>
          Choose…
        </option>
        {candidates.map((s) => (
          <option key={s.id} value={s.id}>
            {s.name}
          </option>
        ))}
      </select>
      <button className="btn" type="submit" disabled={pending} style={{ padding: "2px 10px" }}>
        {pending ? "…" : "Add"}
      </button>
      <button className="btn ghost" type="button" onClick={() => setOpen(false)} style={{ padding: "2px 10px" }}>
        Cancel
      </button>
      {state.error && <span style={{ color: "var(--bad)", fontSize: "var(--text-sm)" }}>{state.error}</span>}
    </form>
  );
}

/**
 * The composer.
 *
 * Typing @ offers the people in this conversation, and only them - a mention
 * is how somebody is asked to look, so it has to reach them. Documents are
 * attached from the client's record by reference, never copied; a new one is
 * uploaded into that client's Documents, with its tier, and then referenced
 * like any other. Whether a restricted document may go at all is the
 * database's call (0106), and it says who cannot open it.
 */
export function Composer({
  conversationId,
  clientId,
  clientName,
  participants,
  documents,
  canSeeRestricted,
}: {
  conversationId: string;
  clientId: string | null;
  clientName: string;
  participants: Person[];
  documents: Attachable[];
  canSeeRestricted: boolean;
}) {
  const [state, action, pending] = useActionState(sendChatMessage, initial);
  const form = useRef<HTMLFormElement>(null);
  const box = useRef<HTMLTextAreaElement>(null);
  const router = useRouter();

  const [body, setBody] = useState("");
  const [picking, setPicking] = useState<string | null>(null);
  // Where the caret goes once the name has been put in. It waits for the
  // textarea to actually hold the new text - set it any sooner and it lands in
  // the middle of what was there before.
  const [caretAfter, setCaretAfter] = useState<number | null>(null);
  const [attached, setAttached] = useState<ChatAttachment[]>([]);
  const [showFiles, setShowFiles] = useState(false);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);

  useEffect(() => {
    if (state.ok) {
      setBody("");
      setAttached([]);
      setShowFiles(false);
      form.current?.reset();
      router.refresh();
    }
  }, [state, router]);

  // Who has been written to by name, so the message can say so.
  const mentioned = participants.filter((p) => body.includes(`@${p.name}`));
  const suggestions =
    picking === null
      ? []
      : participants.filter((p) => p.name.toLowerCase().includes(picking.toLowerCase())).slice(0, 6);

  function onBody(value: string, caret: number) {
    setBody(value);
    const before = value.slice(0, caret);
    const at = before.lastIndexOf("@");
    // Still inside the name being typed: no space has ended it yet.
    setPicking(at >= 0 && !/\s/.test(before.slice(at + 1)) ? before.slice(at + 1) : null);
  }

  useLayoutEffect(() => {
    if (caretAfter === null) return;
    const el = box.current;
    if (el) {
      el.focus();
      el.setSelectionRange(caretAfter, caretAfter);
    }
    setCaretAfter(null);
  }, [caretAfter, body]);

  function insertMention(name: string) {
    const el = box.current;
    if (!el) return;
    const caret = el.selectionStart ?? body.length;
    const before = body.slice(0, caret);
    const at = before.lastIndexOf("@");
    setBody(`${body.slice(0, at)}@${name} ${body.slice(caret)}`);
    setPicking(null);
    setCaretAfter(at + name.length + 2);
  }

  async function upload(file: File, restricted: boolean) {
    if (!clientId) return;
    setUploading(true);
    setUploadError(null);
    try {
      const supabase = createClient();
      const ext = file.name.includes(".") ? file.name.split(".").pop() : "";
      const path = `clients/${clientId}/${crypto.randomUUID()}${ext ? `.${ext}` : ""}`;
      const { error } = await supabase.storage
        .from("client-files")
        .upload(path, file, { contentType: file.type || "application/octet-stream" });
      if (error) {
        setUploadError(`It could not be uploaded: ${error.message}`);
        return;
      }
      const meta = new FormData();
      meta.set("client_id", clientId);
      meta.set("storage_path", path);
      meta.set("filename", file.name);
      meta.set("mime_type", file.type);
      meta.set("size_bytes", String(file.size));
      meta.set("category", "Other");
      if (restricted) meta.set("restricted", "on");
      const result = await recordAttachment({ error: null, ok: null }, meta);
      if (result.error) {
        setUploadError(result.error);
        return;
      }
      // It is on the client's Documents now; the chat points at it there.
      router.refresh();
      setUploadError(null);
    } finally {
      setUploading(false);
    }
  }

  const free = documents.filter((d) => !attached.some((a) => a.id === d.id));

  return (
    <form ref={form} action={action} className="chat-composer">
      {state.error && <div className="alert bad">{state.error}</div>}
      <input type="hidden" name="conversation_id" value={conversationId} />
      <input type="hidden" name="attachments" value={JSON.stringify(attached)} />
      {mentioned.map((p) => (
        <input key={p.id} type="hidden" name="mention" value={p.id} />
      ))}

      {attached.length > 0 && (
        <ul className="attach-row" aria-label="Attached to this message">
          {attached.map((a) => (
            <li key={a.id}>
              <span className="attach-chip">
                <span aria-hidden="true">▤</span> {a.name}
              </span>{" "}
              <button
                type="button"
                className="linkish"
                onClick={() => setAttached(attached.filter((x) => x.id !== a.id))}
              >
                Take off
              </button>
            </li>
          ))}
        </ul>
      )}

      {showFiles && clientId && (
        <div className="attach-panel">
          <p className="lock" style={{ margin: 0 }}>
            {clientName}&apos;s documents. Nothing is copied — the chat points at the document on their record, and it
            keeps its own tier.
          </p>
          {free.length === 0 ? (
            <p className="empty" style={{ margin: "6px 0" }}>
              Nothing on their record to attach yet.
            </p>
          ) : (
            <ul className="attach-row">
              {free.map((d) => (
                <li key={d.id}>
                  <button
                    type="button"
                    className="attach-chip"
                    onClick={() => setAttached([...attached, { kind: d.kind, id: d.id, name: d.name }])}
                  >
                    <span aria-hidden="true">▤</span> {d.name}
                    {d.restricted && <span className="chip bad">restricted</span>}
                  </button>
                </li>
              ))}
            </ul>
          )}

          <div className="row2" style={{ alignItems: "flex-end", gap: 8, marginTop: 6 }}>
            <label className="field" style={{ margin: 0, flex: 2 }}>
              Or upload one to their Documents
              <input
                type="file"
                accept=".pdf,.jpg,.jpeg,.png,.heic,.webp,.tif,.tiff,.doc,.docx,.xls,.xlsx,.txt,.csv"
                disabled={uploading}
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  const restricted = (e.target.form?.elements.namedItem("upload_restricted") as HTMLInputElement | null)?.checked;
                  if (file) void upload(file, Boolean(restricted));
                  e.target.value = "";
                }}
              />
            </label>
            <label style={{ fontSize: "var(--text-md)" }}>
              <input type="checkbox" name="upload_restricted" style={{ width: "auto", marginRight: 6 }} disabled={!canSeeRestricted} />
              Restricted
            </label>
          </div>
          {uploading && <p className="lock">Uploading…</p>}
          {uploadError && <div className="alert bad">{uploadError}</div>}
          <p className="lock" style={{ margin: 0 }}>
            It lands on <Link href={`/clients/${clientId}?tab=documents`}>{clientName}&apos;s Documents</Link> like any
            other document, and can then be attached from the list above.
          </p>
        </div>
      )}

      <div className="composer" style={{ position: "relative" }}>
        <label className="field" style={{ margin: 0, flex: 1 }}>
          <span className="sr-only">Message</span>
          <textarea
            ref={box}
            id="chat-body"
            name="body"
            rows={2}
            maxLength={8000}
            value={body}
            placeholder="Write a message — @ to reach somebody in it"
            onChange={(e) => onBody(e.target.value, e.target.selectionStart ?? 0)}
            onKeyDown={(e) => {
              if (e.key === "Escape") setPicking(null);
              if (e.key === "Enter" && !e.shiftKey && suggestions.length === 0) {
                e.preventDefault();
                form.current?.requestSubmit();
              }
              if (e.key === "Enter" && suggestions.length > 0) {
                e.preventDefault();
                insertMention(suggestions[0].name);
              }
            }}
          />
          {suggestions.length > 0 && (
            <ul className="mention-menu" aria-label="Who to mention">
              {suggestions.map((p) => (
                <li key={p.id}>
                  <button type="button" onClick={() => insertMention(p.name)}>
                    {p.name}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </label>
        <div className="row2" style={{ gap: 6 }}>
          {clientId && (
            <button type="button" className="btn ghost" onClick={() => setShowFiles(!showFiles)}>
              {showFiles ? "Done attaching" : "Attach"}
            </button>
          )}
          <button className="btn gold" type="submit" disabled={pending || (body.trim() === "" && attached.length === 0)}>
            {pending ? "Sending…" : "Send"}
          </button>
        </div>
      </div>
    </form>
  );
}
