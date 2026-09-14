import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { isSha256 } from "@/lib/inbox-storage";

/**
 * Which warrant PDFs, and which of their pages, the CRM still needs.
 *
 * The agent lists the _Warrants folder and sends hashes. A file never seen is
 * wanted whole; a file some of whose pages arrived before a run was cut short
 * is wanted for the pages still missing. A backfill of forty warrants in one
 * PDF can take more than one run, and none of its pages is read twice.
 */
export const dynamic = "force-dynamic";

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let body: { files?: { hash?: string }[] };
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Expected JSON." }, { status: 400 });
  }

  const hashes = [...new Set((body.files ?? []).map((f) => String(f.hash ?? "").toLowerCase()).filter(isSha256))];
  if (hashes.length === 0) return NextResponse.json({ wanted: [] });

  const supabase = createAdminClient();
  const { data: docs, error } = await supabase
    .from("warrant_documents")
    .select("id, sha256, page_count")
    .in("sha256", hashes);
  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const ids = (docs ?? []).map((d) => d.id);
  const { data: pages, error: pagesError } = ids.length
    ? await supabase.from("warrant_pages").select("document_id, page_no").in("document_id", ids)
    : { data: [] as { document_id: string; page_no: number }[], error: null };
  if (pagesError) return NextResponse.json({ error: pagesError.message }, { status: 500 });

  const byHash = new Map((docs ?? []).map((d) => [d.sha256, d]));
  const wanted = hashes.flatMap((hash) => {
    const doc = byHash.get(hash);
    if (!doc) return [{ hash, have: [] as number[] }];
    const have = (pages ?? []).filter((p) => p.document_id === doc.id).map((p) => p.page_no);
    return have.length < doc.page_count ? [{ hash, have }] : [];
  });

  return NextResponse.json({ wanted });
}
