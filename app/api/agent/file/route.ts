import { NextResponse, type NextRequest } from "next/server";
import { createHash } from "node:crypto";
import { createAdminClient } from "@/lib/supabase/admin";
import { extractPdfText } from "@/lib/pdf-text";
import { classifyDocument } from "@/lib/classify-document";
import { parseAuthorizationText } from "@/lib/authorization-parse";
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
 * The hash is recomputed here rather than trusted. The agent sends one so the
 * manifest can be cheap; a hash that does not match the bytes means something
 * changed on the way, and the answer to that is to stop rather than to store
 * a file under a name for a different one.
 */
export const dynamic = "force-dynamic";
export const maxDuration = 60;

const MAX_BYTES = 25 * 1024 * 1024;

export async function POST(request: NextRequest) {
  const secret = process.env.AGENT_SECRET;
  if (!secret) {
    return NextResponse.json({ error: "AGENT_SECRET is not set" }, { status: 500 });
  }
  if (request.headers.get("x-zion-agent") !== secret) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401 });
  }

  const form = await request.formData();
  const file = form.get("file");
  const claimedHash = String(form.get("hash") ?? "").toLowerCase();
  const folder = String(form.get("folder") ?? "").trim();
  const relPath = String(form.get("path") ?? "").trim();
  const modified = String(form.get("modified") ?? "").trim();

  if (!(file instanceof File) || file.size === 0) {
    return NextResponse.json({ error: "No file." }, { status: 400 });
  }
  if (file.size > MAX_BYTES) {
    return NextResponse.json({ error: "Over 25MB." }, { status: 413 });
  }

  const bytes = new Uint8Array(await file.arrayBuffer());
  const actual = createHash("sha256").update(bytes).digest("hex");

  if (claimedHash && claimedHash !== actual) {
    return NextResponse.json(
      { error: "The file does not match the hash sent with it." },
      { status: 400 },
    );
  }

  const supabase = createAdminClient();

  // Seen already: the agent is re-sending, or two folders hold the same file.
  // Either way there is nothing to do, and saying so is not an error.
  const { data: existing } = await supabase
    .from("inbox_documents")
    .select("id, kind, state")
    .eq("sha256", actual)
    .maybeSingle();

  if (existing) {
    return NextResponse.json({ already: true, id: existing.id, kind: existing.kind });
  }

  // ── read it ──────────────────────────────────────────────
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
    ? { kind: "Unreadable" as const, reason: readError, seen: [] }
    : classifyDocument(text);

  // ── whose is it ──────────────────────────────────────────
  const { data: matched } = await supabase.rpc("match_inbox_folder", { p_folder: folder });
  const clientId = (matched as string | null) ?? null;

  // ── what is proposed ─────────────────────────────────────
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
    proposal = { action: "Create an authorization", needs: "confirmation" };
  } else if (classification.kind === "Warrant") {
    // Invoices whose amount matches something on the warrant, offered as
    // candidates. Not applied: a warrant listing three payments and an
    // invoice that happens to share a total is exactly the coincidence that
    // would mark the wrong one paid.
    const amounts = classification.amounts ?? [];
    const { data: candidates } = amounts.length
      ? await supabase
          .from("invoices")
          .select("id, number, date, amount, status, auth_id")
          .eq("status", "Sent")
          .in("amount", amounts.slice(0, 20))
      : { data: [] };

    parsed = { amounts, warrantNumber: classification.warrantNumber ?? null };
    proposal = {
      action: "Mark an invoice paid",
      needs: "confirmation",
      candidates: candidates ?? [],
    };
  } else if (classification.kind === "USOR form") {
    parsed = { usor: classification.usor ?? null, seen: classification.seen };
    proposal = { action: "File against the client", category: "Signed USOR form" };
  } else if (classification.kind === "Other") {
    proposal = { action: "File against the client", category: "Other" };
  }

  // ── keep the file ────────────────────────────────────────
  // Under its hash: the same document arriving twice cannot make two copies,
  // and the name on the machine can change without stranding anything.
  const storagePath = `inbox/${actual.slice(0, 2)}/${actual}.pdf`;
  const { error: uploadError } = await supabase.storage
    .from("client-files")
    .upload(storagePath, bytes, { contentType: "application/pdf", upsert: true });

  if (uploadError) {
    return NextResponse.json({ error: `Not stored: ${uploadError.message}` }, { status: 500 });
  }

  const { data: row, error } = await supabase
    .from("inbox_documents")
    .insert({
      sha256: actual,
      folder_name: folder,
      relative_path: relPath,
      filename: file.name,
      size_bytes: file.size,
      file_modified: modified || null,
      client_id: clientId,
      kind: classification.kind,
      parsed,
      proposal,
      storage_path: storagePath,
    })
    .select("id")
    .single();

  if (error) return NextResponse.json({ error: error.message }, { status: 500 });

  return NextResponse.json({
    id: row.id,
    kind: classification.kind,
    reason: classification.reason,
    matched: Boolean(clientId),
  });
}
