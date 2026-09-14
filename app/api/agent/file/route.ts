import { NextResponse, type NextRequest } from "next/server";
import { createHash } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { extractPdfText } from "@/lib/pdf-text";
import { classifyDocument } from "@/lib/classify-document";
import { parseAuthorizationText } from "@/lib/authorization-parse";
import { authorizationsMentioned, type AuthOnFile } from "@/lib/auth-number";
import { INBOX_BUCKET, STORAGE_MAX_BYTES, inboxStoragePath, isSha256 } from "@/lib/inbox-storage";
import { fileByName, type FilingInput } from "@/lib/file-by-name";
import type { Json } from "@/lib/database.types";

/**
 * One file from the agent.
 *
 * Read, classified, stored, and left as a proposal. Nothing here writes to a
 * client's record, an authorization or an invoice — an authorization read
 * wrongly and applied silently is a rate on somebody's file that nobody typed
 * and nobody checked, and it would be found at the end of a month when the
 * invoice was short.
 *
 * The file arrives one of two ways:
 *
 *   In the request, for anything small enough to get through Vercel's 4.5 MB
 *   request limit.
 *
 *   Already in storage, for anything larger. The agent uploaded it on a URL
 *   from /api/agent/upload-url and sends `stored=1` with the hash; this reads
 *   it back from the path the hash names.
 *
 * Either way the hash is recomputed from the bytes rather than trusted. A hash
 * that does not match means something changed on the way — or that what is in
 * storage at that path is not the file it claims to be — and the answer is to
 * stop rather than record a file under a name for a different one.
 *
 * `reprocess=1` reads a stored document again and replaces the reading. It
 * exists because the first real backfill ran while pdf.js could not load on
 * the server and filed readable documents as scans; the files were kept, so
 * they can be read properly without the agent — which remembers them by hash
 * — ever sending them twice.
 *
 * Every new arrival is then filed by what its name says (lib/file-by-name):
 * a narrative becomes a note, an authorization or invoice goes on its
 * authorization, and whatever the name and text cannot settle waits here as
 * before. `refile=1` does the same for a document already stored - the way the
 * documents that arrived before the rules existed were filed.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const MAX_BYTES = STORAGE_MAX_BYTES;

type Supabase = ReturnType<typeof createAdminClient>;

type Reading = {
  kind: "Authorization" | "USOR form" | "Warrant" | "Other" | "Unreadable";
  reason: string;
  parsed: Json;
  proposal: Json;
  /** The text and filled form fields, for filing by name. Not stored. */
  text: string;
  fields: Record<string, string>;
  /** Set when the text is the agent's OCR of a PDF with no text layer. */
  ocr: { confidence: number | null } | null;
};

/** What the agent's Tesseract read off a scan, as it arrives in the form. */
type OcrPayload = { text: string; engine: string; confidence: number | null; pages: number | null };

function ocrFrom(form: FormData): OcrPayload | null {
  const encoded = form.get("ocr_text_b64");
  if (encoded === null && form.get("ocr") !== "1") return null;
  // Base64 of UTF-8, because the agent builds its multipart body as Latin-1 to
  // carry the PDF's bytes, and a curly quote or an accent would not survive.
  let text = "";
  try {
    text = Buffer.from(String(encoded ?? ""), "base64").toString("utf8");
  } catch {
    text = "";
  }
  const number = (key: string) => {
    const raw = form.get(key);
    const n = raw === null || raw === "" ? NaN : Number(raw);
    return Number.isFinite(n) ? n : null;
  };
  const confidence = number("ocr_confidence");
  const pages = number("ocr_pages");
  return {
    text: text.slice(0, 500_000),
    engine: String(form.get("ocr_engine") ?? "").slice(0, 120),
    confidence: confidence === null ? null : Math.max(0, Math.min(100, confidence)),
    pages: pages && pages > 0 ? Math.round(pages) : null,
  };
}

/** What the file is and what is proposed for it. Writes nothing. */
async function readDocument(
  bytes: Uint8Array,
  supabase: Supabase,
  clientId: string | null,
  ocr: OcrPayload | null = null,
): Promise<Reading> {
  let text = "";
  let fields: Record<string, string> = {};
  let pages = 0;
  let readError = "";
  try {
    const extracted = await extractPdfText(bytes);
    text = extracted.plain;
    fields = extracted.fields;
    pages = extracted.pages;
  } catch (err) {
    readError = err instanceof Error ? err.message : "unreadable";
  }

  // A PDF with no text layer, and the agent's OCR of it: the OCR text is read
  // in its place. Only then. OCR sent with a PDF that has text of its own is
  // ignored, so a reading is never a mix of the two, and a PDF this server
  // could not open at all is not taken on the agent's word to be a scan.
  const fromOcr = !readError && Boolean(ocr?.text.trim()) && text.replace(/\s/g, "").length < 40;
  if (fromOcr && ocr) {
    text = ocr.text;
    fields = {};
  }
  const ocrMark: { [key: string]: Json } = fromOcr
    ? { text_source: "OCR", ocr_confidence: ocr?.confidence ?? null }
    : {};

  const classification = readError
    ? { kind: "Unreadable" as const, reason: `could not be read: ${readError}`, seen: [] as string[] }
    : classifyDocument(text);

  let parsed: Json = null;
  let proposal: Json = null;

  if (classification.kind === "Authorization" && text) {
    const read = parseAuthorizationText(text, { pages, scanned: false });
    parsed = {
      fields: Object.fromEntries(
        Object.entries(read.fields).map(([k, v]) => [k, { value: v.value, source: v.source }]),
      ),
      missing: read.missing,
      warnings: read.warnings,
      ...ocrMark,
    };

    // Which of this client's authorizations it is. Offered, never applied:
    // confirming is a person's act, and the database refuses to put it on
    // another client's authorization or to make a second one with a number
    // already on file.
    let candidates: Json = [];
    if (clientId) {
      const { data: onFile } = await supabase
        .from("authorizations")
        .select("id, number, status, start_date, end_date")
        .eq("client_id", clientId);
      candidates = authorizationsMentioned(
        text,
        read.fields.authNumber?.value,
        (onFile ?? []) as AuthOnFile[],
      ).map((m) => ({
        id: m.id,
        number: m.number,
        status: m.status,
        start_date: m.start_date,
        end_date: m.end_date,
        how: m.how,
      }));
    }
    proposal = { action: "Confirm the authorization", needs: "confirmation", candidates };
  } else if (classification.kind === "Warrant") {
    // Invoices whose amount matches something on the warrant, offered as
    // candidates. Not applied: a warrant listing three payments and an
    // invoice that happens to share a total is exactly the coincidence that
    // would mark the wrong one paid.
    const amounts = "amounts" in classification ? (classification.amounts ?? []) : [];
    const { data: candidates } = amounts.length
      ? await supabase
          .from("invoices")
          .select("id, number, date, amount, status, auth_id")
          .eq("status", "Sent")
          .in("amount", amounts.slice(0, 20))
      : { data: [] };

    parsed = {
      amounts,
      warrantNumber: ("warrantNumber" in classification ? classification.warrantNumber : null) ?? null,
    };
    proposal = { action: "Mark an invoice paid", needs: "confirmation", candidates: candidates ?? [] };
  } else if (classification.kind === "USOR form") {
    parsed = {
      usor: ("usor" in classification ? classification.usor : null) ?? null,
      seen: classification.seen,
      ...ocrMark,
    };
    proposal = { action: "File against the client", category: "Signed USOR form" };
  } else if (classification.kind === "Other") {
    parsed = fromOcr ? ocrMark : null;
    proposal = { action: "File against the client", category: "Other" };
  } else {
    // Unreadable. The reason is kept on the row: the first backfill filed 36
    // readable documents as scans and nothing recorded why, so the cause could
    // only be found by re-reading the files by hand. A wrong "Unreadable" now
    // leads straight to what went wrong.
    parsed = { reason: classification.reason };
  }

  return {
    kind: classification.kind,
    reason: classification.reason,
    parsed,
    proposal,
    text,
    fields,
    ocr: fromOcr ? { confidence: ocr?.confidence ?? null } : null,
  };
}

/** File it by its name. A failure here never loses the document: it stays waiting. */
async function fileArrival(
  supabase: Supabase,
  doc: FilingInput["doc"],
  reading: Pick<Reading, "text" | "fields" | "ocr">,
): Promise<string> {
  try {
    const result = await fileByName(supabase, {
      doc,
      text: reading.text,
      fields: reading.fields,
      ocr: reading.ocr,
    });
    return `${result.action}: ${result.detail}`;
  } catch (err) {
    return `left waiting: ${err instanceof Error ? err.message : "filing failed"}`;
  }
}

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

  const file = form.get("file");
  const claimedHash = String(form.get("hash") ?? "").toLowerCase();
  const folder = String(form.get("folder") ?? "").trim();
  const relPath = String(form.get("path") ?? "").trim();
  const modified = String(form.get("modified") ?? "").trim();
  const stored = form.get("stored") === "1";
  const reprocess = form.get("reprocess") === "1";
  const refile = form.get("refile") === "1";
  const ocrMode = form.get("ocr") === "1";
  const ocrPayload = ocrFrom(form);

  const supabase = createAdminClient();

  // ── the bytes ────────────────────────────────────────────
  let bytes: Uint8Array;
  let filename: string;

  if (file instanceof File && file.size > 0) {
    if (file.size > MAX_BYTES) {
      return NextResponse.json(
        { error: `Over the ${MAX_BYTES / (1024 * 1024)} MB storage limit.` },
        { status: 413 },
      );
    }
    bytes = new Uint8Array(await file.arrayBuffer());
    filename = file.name;
  } else if (stored || reprocess || refile || ocrMode) {
    if (!isSha256(claimedHash)) {
      return NextResponse.json(
        { error: "A stored document is named by its SHA-256 hash." },
        { status: 400 },
      );
    }
    const { data: blob, error } = await supabase.storage
      .from(INBOX_BUCKET)
      .download(inboxStoragePath(claimedHash));
    if (error || !blob) {
      return NextResponse.json(
        { error: "Nothing is stored under that hash. Upload it first." },
        { status: 404 },
      );
    }
    bytes = new Uint8Array(await blob.arrayBuffer());
    filename = String(form.get("filename") ?? "").trim() || `${claimedHash}.pdf`;
  } else {
    return NextResponse.json({ error: "No file." }, { status: 400 });
  }

  const actual = createHash("sha256").update(bytes).digest("hex");

  // The size as it arrived, taken before anything reads the bytes. Reading
  // once emptied them in place, and the size recorded afterwards was 0.
  const size = bytes.byteLength;

  if ((claimedHash || stored || reprocess) && claimedHash !== actual) {
    return NextResponse.json(
      { error: "The file does not match the hash sent with it." },
      { status: 400 },
    );
  }

  const { data: existing } = await supabase
    .from("inbox_documents")
    .select(
      "id, kind, state, client_id, parsed, proposal, filename, file_modified, storage_path, ocr_text, ocr_engine, ocr_confidence, ocr_pages",
    )
    .eq("sha256", actual)
    .maybeSingle();

  // ── filing one already here by its name ─────────────────
  if (refile) {
    if (!existing) {
      return NextResponse.json({ error: "There is no such document to file." }, { status: 404 });
    }
    // Read for the text and form fields only - with the OCR already on record
    // for a scan. The stored reading is not replaced here; reprocess does that.
    const onRecord: OcrPayload | null = existing.ocr_text
      ? {
          text: existing.ocr_text,
          engine: existing.ocr_engine,
          confidence: existing.ocr_confidence === null ? null : Number(existing.ocr_confidence),
          pages: existing.ocr_pages,
        }
      : null;
    const reading = await readDocument(bytes, supabase, existing.client_id, onRecord);
    const filed = await fileArrival(supabase, existing, reading);
    return NextResponse.json({ id: existing.id, refiled: true, filed });
  }

  // ── the agent's OCR of a scan already here ──────────────
  if (ocrMode) {
    if (!existing) {
      return NextResponse.json({ error: "There is no such document to read." }, { status: 404 });
    }
    if (!ocrPayload) {
      return NextResponse.json({ error: "Send the OCR text." }, { status: 400 });
    }

    // The server reads the file itself first. OCR is taken only for a PDF with
    // no text layer; for one with text of its own it is not even kept.
    const reading = await readDocument(bytes, supabase, existing.client_id, ocrPayload);
    if (!reading.ocr && reading.kind !== "Unreadable") {
      return NextResponse.json({ id: existing.id, ocr: "ignored: the file has text of its own" });
    }

    // Recorded even when Tesseract found nothing, so it is not asked for again.
    const { error: ocrError } = await supabase
      .from("inbox_documents")
      .update({
        ocr_text: ocrPayload.text,
        ocr_engine: ocrPayload.engine,
        ocr_confidence: ocrPayload.confidence,
        ocr_pages: ocrPayload.pages,
        ocr_at: new Date().toISOString(),
      })
      .eq("id", existing.id);
    if (ocrError) return NextResponse.json({ error: ocrError.message }, { status: 500 });

    if (!reading.ocr) {
      return NextResponse.json({ id: existing.id, ocr: "recorded: nothing readable in it" });
    }

    // A waiting document takes the OCR reading. A decided one keeps its reading
    // and its decision, and is only added to by filing.
    let doc: FilingInput["doc"] = existing;
    if (existing.state === "Pending") {
      const { data: updated } = await supabase
        .from("inbox_documents")
        .update({ kind: reading.kind, parsed: reading.parsed, proposal: reading.proposal })
        .eq("id", existing.id)
        .eq("state", "Pending")
        .select("id, kind, state, client_id, parsed, proposal, filename, file_modified, storage_path")
        .maybeSingle();
      if (updated) doc = updated;
    }

    const filed = await fileArrival(supabase, doc, reading);
    return NextResponse.json({ id: existing.id, ocr: "read", kind: reading.kind, filed });
  }

  // ── reading one again ────────────────────────────────────
  if (reprocess) {
    if (!existing) {
      return NextResponse.json({ error: "There is no such document to read again." }, { status: 404 });
    }

    // Marked Unreadable with no reason recorded (read while pdf.js could not
    // load at all), or with a reason that is a read error rather than a finding
    // ("could not be read: ..."). Neither was ever a reading, and a person
    // having filed the document since does not turn it into one, so it may be
    // read again. "No text in the file" is a finding: a document decided on it
    // keeps it, as does any other decided document.
    const earlierReading = existing.parsed as { reason?: unknown } | null;
    const earlierReason =
      earlierReading && typeof earlierReading === "object" && typeof earlierReading.reason === "string"
        ? earlierReading.reason
        : null;
    const unread =
      existing.kind === "Unreadable" &&
      (earlierReason === null || earlierReason.startsWith("could not be read:"));

    if (existing.state !== "Pending" && !unread) {
      return NextResponse.json({ already: true, id: existing.id, kind: existing.kind, left: "decided" });
    }

    const reading = await readDocument(bytes, supabase, existing.client_id);

    // The reading only. What somebody decided — filed, set aside, linked, and
    // the words recorded for it — stands untouched, and the update applies
    // only if that decision has not changed since this request looked.
    const { error } = await supabase
      .from("inbox_documents")
      .update({ kind: reading.kind, parsed: reading.parsed, proposal: reading.proposal })
      .eq("id", existing.id)
      .eq("state", existing.state);

    if (error) return NextResponse.json({ error: error.message }, { status: 500 });

    return NextResponse.json({
      id: existing.id,
      reread: true,
      was: existing.kind,
      kind: reading.kind,
      reason: reading.reason,
    });
  }

  // Seen already: the agent is re-sending, or two folders hold the same file.
  // Either way there is nothing to do, and saying so is not an error.
  if (existing) {
    return NextResponse.json({ already: true, id: existing.id, kind: existing.kind });
  }

  // ── whose is it ──────────────────────────────────────────
  // Before reading, so an authorization can be matched against that client's
  // authorizations on file.
  const { data: matched } = await supabase.rpc("match_inbox_folder", { p_folder: folder });
  const clientId = (matched as string | null) ?? null;

  // ── read it ──────────────────────────────────────────────
  const reading = await readDocument(bytes, supabase, clientId, ocrPayload);

  // ── keep the file ────────────────────────────────────────
  const storagePath = inboxStoragePath(actual);
  if (!stored) {
    // Refuse rather than store something other than what arrived. Bytes that
    // changed length while being read are not the file the hash names.
    if (bytes.byteLength !== size) {
      return NextResponse.json(
        { error: "The file changed while it was being read. Nothing was stored." },
        { status: 500 },
      );
    }
    const { error: uploadError } = await supabase.storage
      .from(INBOX_BUCKET)
      .upload(storagePath, bytes, { contentType: "application/pdf", upsert: true });

    if (uploadError) {
      return NextResponse.json({ error: `Not stored: ${uploadError.message}` }, { status: 500 });
    }
  }

  const { data: row, error } = await supabase
    .from("inbox_documents")
    .insert({
      sha256: actual,
      folder_name: folder,
      relative_path: relPath,
      filename,
      size_bytes: size,
      file_modified: modified || null,
      client_id: clientId,
      kind: reading.kind,
      parsed: reading.parsed,
      proposal: reading.proposal,
      storage_path: storagePath,
      // The agent's OCR, kept only when it is what the document was read from.
      ...(reading.ocr && ocrPayload
        ? {
            ocr_text: ocrPayload.text,
            ocr_engine: ocrPayload.engine,
            ocr_confidence: ocrPayload.confidence,
            ocr_pages: ocrPayload.pages,
            ocr_at: new Date().toISOString(),
          }
        : {}),
    })
    .select("id, kind, state, client_id, parsed, proposal, filename, file_modified, storage_path")
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  const filed = await fileArrival(supabase, row, reading);

  return NextResponse.json({
    id: row.id,
    kind: reading.kind,
    reason: reading.reason,
    matched: Boolean(clientId),
    filed,
  });
}
