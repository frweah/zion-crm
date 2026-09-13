import { NextResponse, type NextRequest } from "next/server";
import { createHash } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { extractPdfText } from "@/lib/pdf-text";
import { classifyDocument } from "@/lib/classify-document";
import { parseAuthorizationText } from "@/lib/authorization-parse";
import { authorizationsMentioned, type AuthOnFile } from "@/lib/auth-number";
import { INBOX_BUCKET, STORAGE_MAX_BYTES, inboxStoragePath, isSha256 } from "@/lib/inbox-storage";
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
};

/** What the file is and what is proposed for it. Writes nothing. */
async function readDocument(
  bytes: Uint8Array,
  supabase: Supabase,
  clientId: string | null,
): Promise<Reading> {
  let text = "";
  let pages = 0;
  let readError = "";
  try {
    const extracted = await extractPdfText(bytes);
    text = extracted.plain;
    pages = extracted.pages;
  } catch (err) {
    readError = err instanceof Error ? err.message : "unreadable";
  }

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
    };
    proposal = { action: "File against the client", category: "Signed USOR form" };
  } else if (classification.kind === "Other") {
    proposal = { action: "File against the client", category: "Other" };
  } else {
    // Unreadable. The reason is kept on the row: the first backfill filed 36
    // readable documents as scans and nothing recorded why, so the cause could
    // only be found by re-reading the files by hand. A wrong "Unreadable" now
    // leads straight to what went wrong.
    parsed = { reason: classification.reason };
  }

  return { kind: classification.kind, reason: classification.reason, parsed, proposal };
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
  } else if (stored || reprocess) {
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

  if ((claimedHash || stored || reprocess) && claimedHash !== actual) {
    return NextResponse.json(
      { error: "The file does not match the hash sent with it." },
      { status: 400 },
    );
  }

  const { data: existing } = await supabase
    .from("inbox_documents")
    .select("id, kind, state, client_id, parsed")
    .eq("sha256", actual)
    .maybeSingle();

  // ── reading one again ────────────────────────────────────
  if (reprocess) {
    if (!existing) {
      return NextResponse.json({ error: "There is no such document to read again." }, { status: 404 });
    }

    // Marked Unreadable with no reason recorded: that is the server reading it
    // while pdf.js could not load, which was never a reading at all. A person
    // having filed such a document since does not turn it into one, so it may
    // be read again. Any other decided document keeps the reading it had.
    const earlierReading = existing.parsed as { reason?: unknown } | null;
    const unread =
      existing.kind === "Unreadable" &&
      !(earlierReading && typeof earlierReading === "object" && "reason" in earlierReading);

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
  const reading = await readDocument(bytes, supabase, clientId);

  // ── keep the file ────────────────────────────────────────
  const storagePath = inboxStoragePath(actual);
  if (!stored) {
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
      size_bytes: bytes.byteLength,
      file_modified: modified || null,
      client_id: clientId,
      kind: reading.kind,
      parsed: reading.parsed,
      proposal: reading.proposal,
      storage_path: storagePath,
    })
    .select("id")
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({
    id: row.id,
    kind: reading.kind,
    reason: reading.reason,
    matched: Boolean(clientId),
  });
}
