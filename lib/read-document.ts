import "server-only";
import type { createAdminClient } from "@/lib/supabase/admin";
import { extractPdfText } from "@/lib/pdf-text";
import { classifyDocument } from "@/lib/classify-document";
import { parseAuthorizationText } from "@/lib/authorization-parse";
import { authorizationsMentioned, type AuthOnFile } from "@/lib/auth-number";
import type { Json } from "@/lib/database.types";

/**
 * What a document is, and what is proposed for it. One reader.
 *
 * This was inside app/api/agent/file/route.ts, where it was the only thing
 * that read a PDF because the agent was the only way a PDF arrived. Mail from
 * a counselor is a second way in (Intake Automation Brief, 10 Oct 2026), and
 * a second copy of this would be a second answer to "is this an
 * authorization" - which is the question the whole intake rests on. So it
 * lives here and both call it.
 *
 * It writes nothing. An authorization read wrongly and applied silently is a
 * rate on somebody's file that nobody typed and nobody checked, and it would
 * be found at the end of a month when the invoice was short.
 */
type Supabase = ReturnType<typeof createAdminClient>;

export type Reading = {
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
export type OcrPayload = { text: string; engine: string; confidence: number | null; pages: number | null };

export function ocrFrom(form: FormData): OcrPayload | null {
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
export async function readDocument(
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
    // Not settled here, and no invoice is offered to mark paid. A stub in a
    // client's folder goes through the warrant pipeline like one in _Warrants:
    // the agent reads it page by page, every line must prove itself (both
    // copies of the V-number agree, the page adds up, the authorization is on
    // file), and the pipeline closes this entry (lib/warrant-routing).
    const amounts = "amounts" in classification ? (classification.amounts ?? []) : [];
    parsed = {
      amounts,
      warrantNumber: ("warrantNumber" in classification ? classification.warrantNumber : null) ?? null,
    };
    proposal = { action: "Read as a warrant", needs: "the warrant pipeline" };
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
