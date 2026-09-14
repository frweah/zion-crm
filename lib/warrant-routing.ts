import "server-only";
import type { createAdminClient } from "@/lib/supabase/admin";

type Supabase = ReturnType<typeof createAdminClient>;

/**
 * A warrant stub that arrived with a client's documents, settled by the
 * warrant pipeline rather than by a person in the inbox.
 *
 * The agent reads the stub page by page into /api/agent/warrants, where every
 * line has to prove itself before anything is paid. Once every page is in, the
 * inbox entry closes with what the pages came to. If no page of it was a
 * warrant at all - a letter that happened to mention one - it goes back to the
 * inbox as an ordinary document for somebody to file.
 *
 * Until then it waits, and says how far it has got. Only the service role can
 * close it: the database refuses a person filing or setting it aside
 * (public.inbox_warrant_guard).
 */
export async function settleRoutedWarrant(supabase: Supabase, sha256: string): Promise<string | null> {
  const { data: doc } = await supabase
    .from("inbox_documents")
    .select("id, kind, state")
    .eq("sha256", sha256)
    .maybeSingle();
  if (!doc || doc.kind !== "Warrant" || doc.state !== "Pending") return null;

  const { data: warrantDoc } = await supabase
    .from("warrant_documents")
    .select("id, page_count")
    .eq("sha256", sha256)
    .maybeSingle();
  if (!warrantDoc) return "waiting for the agent to read it as a warrant";

  const { data: pageRows } = await supabase
    .from("warrant_pages")
    .select("id, status")
    .eq("document_id", warrantDoc.id);
  const pages = pageRows ?? [];
  if (pages.length < warrantDoc.page_count) {
    return `${pages.length} of ${warrantDoc.page_count} page(s) read as a warrant so far`;
  }

  if (pages.every((p) => p.status === "Not a warrant")) {
    await supabase
      .from("inbox_documents")
      .update({ kind: "Other", proposal: { action: "File against the client", category: "Other" } })
      .eq("id", doc.id)
      .eq("state", "Pending");
    return "no page of it is a warrant; back in the inbox to be filed";
  }

  const { data: lineRows } = await supabase
    .from("warrant_lines")
    .select("status")
    .in("page_id", pages.map((p) => p.id));
  const lines = lineRows ?? [];
  const count = (s: string) => lines.filter((l) => l.status === s).length;
  const outcome =
    `Read as a warrant on Billing → Warrants: ${pages.length} page(s), ` +
    `${count("Reconciled")} line(s) paid, ${count("Already recorded")} already recorded, ` +
    `${count("Needs review")} to review`;

  await supabase
    .from("inbox_documents")
    .update({ state: "Filed", decided_at: new Date().toISOString(), outcome })
    .eq("id", doc.id)
    .eq("state", "Pending");
  return outcome;
}
