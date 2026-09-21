"use server";

import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { getCurrentStaff } from "@/lib/session";
import { INBOX_BUCKET } from "@/lib/inbox-storage";

/**
 * A fresh link to a document's PDF, for the viewer's "Try again".
 *
 * The link on the page lasts fifteen minutes, and a panel left open longer
 * than that fails on its next load - the likeliest cause of the glitch the
 * review saw (punch list #16). The row is read as the person first, so the
 * rules that decided they may see the document decide whether they get a
 * link; only then is one minted.
 */
export async function freshInboxPdfUrl(docId: string): Promise<string | null> {
  const me = await getCurrentStaff();
  if (!me || !docId) return null;
  const supabase = await createClient();
  const { data } = await supabase.from("inbox_pending").select("storage_path").eq("id", docId).maybeSingle();
  const path = (data as { storage_path?: string | null } | null)?.storage_path;
  if (!path) return null;
  const { data: signed } = await createAdminClient().storage.from(INBOX_BUCKET).createSignedUrl(path, 60 * 15);
  return signed?.signedUrl ?? null;
}

/**
 * What the viewer saw, into the server log (Vercel's), so a failure is
 * something that can be looked up rather than a thing somebody mentions once.
 *
 * The document's id and nothing else about it: a filename is usually a
 * client's name, and the log is not where client names go.
 */
export async function noteViewerEvent(e: {
  docId: string;
  event: "loaded" | "failed" | "timeout" | "retried";
  ms?: number;
  detail?: string;
}): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const line = JSON.stringify({
    viewer: "inbox-pdf",
    event: e.event,
    doc: String(e.docId).slice(0, 64),
    ms: typeof e.ms === "number" ? Math.round(e.ms) : undefined,
    detail: e.detail ? String(e.detail).slice(0, 200) : undefined,
    staff: me.id,
  });
  if (e.event === "loaded") console.info(`[pdf-viewer] ${line}`);
  else console.warn(`[pdf-viewer] ${line}`);
}
