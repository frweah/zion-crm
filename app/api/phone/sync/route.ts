import { type NextRequest } from "next/server";
import { phoneStaff, fresh } from "@/lib/phone/server";
import { addNote } from "@/app/(app)/clients/[id]/actions";
import { recordAttachment } from "@/app/(app)/clients/[id]/files/actions";

/**
 * Where the phone sends what it saved with no signal (0342).
 *
 * One thing per request, each carrying the key the phone made when the
 * button was pressed, and each handed to the same action or database function
 * the desk uses - a second way in must not be a second set of rules. What
 * makes a retry safe is the key: a note and a document use it as their id, and
 * the clock, a To file confirmation and a Team message claim it in
 * `phone_receipts` in the same transaction as the work.
 *
 * The answer tells the phone which of three things happened, because it
 * does something different with each:
 *
 *   200  done, or already done - take it off the phone.
 *   422  refused, with the sentence why - show it, keep it, let the person
 *        decide. Sending it again unchanged would only be refused again.
 *   503  the practice did not answer - keep it and try again later.
 *
 * (And 401/403 from phoneStaff: signed out, or a gate - keep everything.)
 */
export const dynamic = "force-dynamic";
export const maxDuration = 30;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TRANSIENT = /timeout|timed out|fetch failed|ECONN|network|socket|503|502|504|too many/i;

type Item = {
  key: string;
  kind: "note" | "file" | "clock" | "tofile" | "team";
  at: string;
  [field: string]: unknown;
};

function said(error: string | null | undefined, ok: string | null | undefined) {
  if (!error) return fresh({ ok: ok ?? "Sent." });
  return fresh({ error }, TRANSIENT.test(error) ? 503 : 422);
}

function form(pairs: Record<string, unknown>) {
  const fd = new FormData();
  for (const [k, v] of Object.entries(pairs)) {
    if (v === undefined || v === null) continue;
    if (Array.isArray(v)) for (const x of v) fd.append(k, String(x));
    else fd.set(k, String(v));
  }
  return fd;
}

export async function POST(request: NextRequest) {
  const who = await phoneStaff();
  if ("response" in who) return who.response;
  const { supabase } = who;

  let item: Item;
  try {
    item = (await request.json()) as Item;
  } catch {
    return fresh({ error: "That arrived unreadable. Nothing was done." }, 422);
  }
  if (!item || !UUID.test(String(item.key ?? ""))) {
    return fresh({ error: "That came without its key. Nothing was done." }, 422);
  }
  const at = String(item.at ?? "");
  const s = (k: string) => String(item[k] ?? "").trim();

  if (item.kind === "note") {
    const result = await addNote(
      { error: null, ok: null },
      form({
        id: s("client_id"),
        key: item.key,
        written_at: at,
        text: s("text"),
        type: s("type") || "General",
        category: s("category"),
        // The same default the Notes tab and the "+" offer.
        visible_roles: ["Job Search"],
      }),
    );
    return said(result.error, result.ok);
  }

  if (item.kind === "file") {
    // The bytes went straight from the phone to storage under this key; this
    // records the row, which is what puts it on the client's Documents.
    const path = s("storage_path");
    if (!path.startsWith(`clients/${s("client_id")}/${item.key}`)) {
      return fresh({ error: "That file is not where its key says. Nothing was recorded." }, 422);
    }
    const result = await recordAttachment(
      { error: null, ok: null },
      form({
        key: item.key,
        client_id: s("client_id"),
        storage_path: path,
        mime_type: s("mime_type"),
        size_bytes: s("size_bytes"),
        category: s("category") || "Other",
        filename: s("filename"),
        document_date: s("document_date"),
        sha256: s("sha256"),
        note: s("note"),
        restricted: item.restricted ? "on" : undefined,
      }),
    );
    return said(result.error, result.ok);
  }

  if (item.kind === "clock") {
    const { data, error } = await supabase.rpc("phone_clock", { p_key: item.key, p_kind: s("what"), p_at: at });
    if (error) return said(error.message, null);
    return fresh({ ok: data === "already" ? "Already sent." : "Sent." });
  }

  if (item.kind === "tofile") {
    const { data, error } = await supabase.rpc("phone_to_file_confirm", {
      p_key: item.key,
      p_at: at,
      p_item: s("item"),
      p_outcome: s("outcome"),
      p_note: s("note"),
      p_category: s("category") || undefined,
    });
    if (error) return said(error.message, null);
    return fresh({ ok: data === "already" ? "Already sent." : "Sent." });
  }

  if (item.kind === "team") {
    const { data, error } = await supabase.rpc("phone_post_message", {
      p_key: item.key,
      p_at: at,
      p_conversation: s("conversation_id"),
      p_body: s("body"),
    });
    if (error) return said(error.message, null);
    return fresh({ ok: data === "already" ? "Already sent." : "Sent." });
  }

  return fresh({ error: "The phone sent something this does not know. Nothing was done." }, 422);
}
