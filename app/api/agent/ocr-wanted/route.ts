import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";

/**
 * The scans the CRM would like read.
 *
 * The agent reads a PDF with Tesseract before sending it when it can tell the
 * PDF has no text layer. When it cannot tell - or the document arrived before
 * the agent could read at all - the CRM finds no text in it, and this is how it
 * asks: the documents with no text of their own and no OCR yet, waiting ones
 * first, a handful per run so one run never takes the machine for an hour.
 *
 * The answer is hashes and the paths the agent sent, nothing else. The agent
 * reads its own copy of the file and sends the text back with `ocr=1`.
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

  const body = (await request.json().catch(() => ({}))) as { limit?: unknown };
  const limit = Math.min(Math.max(Number(body.limit) || 25, 1), 100);

  const supabase = createAdminClient();

  // Waiting documents first: those are the ones a reading can still file.
  const pick = async (pending: boolean, n: number) => {
    if (n <= 0) return [];
    const query = supabase
      .from("inbox_documents")
      .select("sha256, relative_path")
      .eq("kind", "Unreadable")
      .is("ocr_at", null)
      .order("first_seen")
      .limit(n);
    const { data } = pending ? await query.eq("state", "Pending") : await query.neq("state", "Pending");
    return data ?? [];
  };

  const waiting = await pick(true, limit);
  const decided = await pick(false, limit - waiting.length);

  return NextResponse.json({
    wanted: [...waiting, ...decided].map((d) => ({ hash: d.sha256, path: d.relative_path })),
  });
}
