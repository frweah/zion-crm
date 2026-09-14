import { NextResponse, type NextRequest } from "next/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { isSha256 } from "@/lib/inbox-storage";
import { parseWarrantPage, linesTotal } from "@/lib/warrant-parse";
import { settleRoutedWarrant } from "@/lib/warrant-routing";

/**
 * One page of a warrant PDF, read by the agent.
 *
 * The agent draws each page, turns it upright, reads it with Tesseract and
 * sends the text with a picture of the page. Here the page is kept - the
 * picture is what a person looks at when a line needs review - its lines are
 * parsed, and public.reconcile_warrant_page decides what each line is: a
 * payment, one already recorded, or something to look at.
 *
 * The agent's reading is never trusted as a payment on its own. The database
 * checks the page against itself - both V-number copies agree, the lines add
 * up to the total - and against the authorizations on file.
 *
 * A page already received is left alone and reported, so a run cut short can
 * simply send the file again.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const MAX_IMAGE = 8 * 1024 * 1024;

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return NextResponse.json({ error: "Expected a multipart form." }, { status: 400 });
  }

  const str = (k: string) => String(form.get(k) ?? "").trim();
  const hash = str("hash").toLowerCase();
  const pageNo = Number(str("page_no"));
  const pageCount = Number(str("page_count"));
  if (!isSha256(hash)) return NextResponse.json({ error: "A warrant file is named by its SHA-256 hash." }, { status: 400 });
  if (!Number.isInteger(pageNo) || !Number.isInteger(pageCount) || pageNo < 1 || pageCount < pageNo) {
    return NextResponse.json({ error: "Give the page number and how many pages the file has." }, { status: 400 });
  }

  let text = "";
  try {
    text = Buffer.from(str("ocr_text_b64"), "base64").toString("utf8").slice(0, 200_000);
  } catch {
    text = "";
  }
  const confidenceRaw = str("ocr_confidence");
  const confidence = confidenceRaw === "" || !Number.isFinite(Number(confidenceRaw)) ? null : Math.max(0, Math.min(100, Number(confidenceRaw)));
  const rotation = [0, 90, 180, 270].includes(Number(str("rotation"))) ? Number(str("rotation")) : 0;

  const supabase = createAdminClient();

  // ── the file ─────────────────────────────────────────────
  let { data: doc } = await supabase.from("warrant_documents").select("id, page_count").eq("sha256", hash).maybeSingle();
  if (!doc) {
    const { data: created, error } = await supabase
      .from("warrant_documents")
      .insert({ sha256: hash, filename: str("filename") || `${hash}.pdf`, relative_path: str("path"), page_count: pageCount })
      .select("id, page_count")
      .single();
    if (error) {
      // Two pages of a new file arriving at once: the other one made it.
      ({ data: doc } = await supabase.from("warrant_documents").select("id, page_count").eq("sha256", hash).maybeSingle());
      if (!doc) return NextResponse.json({ error: error.message }, { status: 500 });
    } else {
      doc = created;
    }
  }

  const { data: existing } = await supabase
    .from("warrant_pages")
    .select("id, status, warrant_no")
    .eq("document_id", doc.id)
    .eq("page_no", pageNo)
    .maybeSingle();
  if (existing) {
    return NextResponse.json({ already: true, page_id: existing.id, status: existing.status, warrant_no: existing.warrant_no });
  }

  // ── the picture ──────────────────────────────────────────
  let imagePath = "";
  const image = form.get("image");
  if (image instanceof File && image.size > 0) {
    if (image.size > MAX_IMAGE) {
      return NextResponse.json({ error: "The page image is over 8 MB." }, { status: 413 });
    }
    imagePath = `${hash}/page-${String(pageNo).padStart(3, "0")}.jpg`;
    const { error: uploadError } = await supabase.storage
      .from("warrants")
      .upload(imagePath, new Uint8Array(await image.arrayBuffer()), { contentType: "image/jpeg", upsert: true });
    if (uploadError) return NextResponse.json({ error: `Page image not stored: ${uploadError.message}` }, { status: 500 });
  }

  // ── the reading ──────────────────────────────────────────
  const parsed = parseWarrantPage(text);
  const notAWarrant = parsed.lines.length === 0 && !parsed.warrantNo;

  const { data: page, error: pageError } = await supabase
    .from("warrant_pages")
    .insert({
      document_id: doc.id,
      page_no: pageNo,
      image_path: imagePath,
      ocr_text: text,
      ocr_confidence: confidence,
      rotation,
      warrant_no: parsed.warrantNo,
      warrant_date: parsed.warrantDate,
      total: parsed.total,
      lines_total: linesTotal(parsed),
      status: notAWarrant ? "Not a warrant" : "Needs review",
      problems: parsed.problems,
    })
    .select("id")
    .single();
  if (pageError) {
    if (pageError.code === "23505") return NextResponse.json({ already: true });
    return NextResponse.json({ error: pageError.message }, { status: 500 });
  }

  if (parsed.lines.length) {
    const { error: linesError } = await supabase.from("warrant_lines").insert(
      parsed.lines.map((l) => ({
        page_id: page.id,
        line_no: l.lineNo,
        raw: l.raw.slice(0, 1000),
        dept: l.dept,
        voucher: l.voucher,
        invoice_ref: l.invoiceRef,
        described_ref: l.describedRef,
        client_code: l.clientCode,
        client_name: l.clientName,
        service_date: l.serviceDate,
        described_amount: l.describedAmount,
        amount: l.amount,
      })),
    );
    if (linesError) return NextResponse.json({ error: linesError.message }, { status: 500 });
  }

  let counts = { reconciled: 0, already_recorded: 0, needs_review: 0 };
  if (!notAWarrant) {
    const { data, error } = await supabase.rpc("reconcile_warrant_page", { p_page: page.id });
    if (error) return NextResponse.json({ error: error.message }, { status: 500 });
    const row = Array.isArray(data) ? data[0] : null;
    counts = {
      reconciled: Number(row?.reconciled ?? 0),
      already_recorded: Number(row?.already_recorded ?? 0),
      needs_review: Number(row?.needs_review ?? 0),
    };
  }

  const { data: final } = await supabase.from("warrant_pages").select("status").eq("id", page.id).single();

  // A stub that arrived with a client's documents closes in the inbox once its
  // last page is in.
  await settleRoutedWarrant(supabase, hash);

  return NextResponse.json({
    page_id: page.id,
    status: final?.status ?? (notAWarrant ? "Not a warrant" : "Needs review"),
    warrant_no: parsed.warrantNo,
    lines: parsed.lines.length,
    ...counts,
    problems: parsed.problems,
  });
}
