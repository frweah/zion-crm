import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { classifyDocument } from "@/lib/classify-document";

/**
 * The agent's reading of a photo taken on a phone (0343).
 *
 * Same rules as a scan: the agent sends a reading only when Tesseract read
 * the photo. Text is "read"; read and found nothing is "nothing readable";
 * a failure is never sent, so the photo stays "not read yet" and is asked for
 * again. What the text says the document is goes beside it as a proposal -
 * nothing is filed, confirmed or put on an authorization from here.
 *
 * Only a photo still waiting is written, so a late or repeated answer cannot
 * replace a reading already recorded.
 */
export const dynamic = "force-dynamic";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const body = (await request.json().catch(() => null)) as {
    id?: unknown;
    ocr_text_b64?: unknown;
    ocr_confidence?: unknown;
  } | null;
  const id = String(body?.id ?? "");
  if (!UUID.test(id)) return NextResponse.json({ error: "Which photo?" }, { status: 400 });

  let text = "";
  try {
    text = Buffer.from(String(body?.ocr_text_b64 ?? ""), "base64").toString("utf8").slice(0, 500_000);
  } catch {
    return NextResponse.json({ error: "The reading arrived unreadable." }, { status: 400 });
  }
  const raw = Number(body?.ocr_confidence);
  const confidence = Number.isFinite(raw) ? Math.max(0, Math.min(100, raw)) : null;
  const found = text.trim().length > 0;

  const supabase = createAdminClient();
  const { data, error } = await supabase
    .from("attachments")
    .update({
      ocr_state: found ? "read" : "nothing readable",
      ocr_text: found ? text : null,
      ocr_confidence: confidence,
      ocr_kind: found ? classifyDocument(text).kind : null,
      ocr_at: new Date().toISOString(),
    })
    .eq("id", id)
    .eq("ocr_state", "not read yet")
    .select("id, ocr_state, ocr_kind")
    .maybeSingle();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });
  if (!data) return NextResponse.json({ ocr: "already read, or not waiting" });
  return NextResponse.json({ ocr: data.ocr_state, kind: data.ocr_kind });
}
