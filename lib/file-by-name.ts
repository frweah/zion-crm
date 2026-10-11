import "server-only";
import type { createAdminClient } from "@/lib/supabase/admin";
import {
  planDocument,
  vKey,
  type AuthLite,
  type Category,
  type NameReading,
  type Plan,
} from "@/lib/filename-rules";
import { parseAuthorizationText } from "@/lib/authorization-parse";
import type { Json } from "@/lib/database.types";

/**
 * Filing a document by what its name says.
 *
 * lib/filename-rules.ts decides; this does it, through the database functions
 * that refuse the ways it could go wrong (0077): one note per document, never
 * another client's authorization, never an overwritten date.
 *
 * Runs as the service role - for every new arrival from the agent, and once
 * over everything already in the inbox. What it cannot settle stays waiting,
 * with what the name said and why it stopped, for a person to finish.
 *
 * A document somebody already decided about is only ever added to: its note,
 * or its place on an authorization. It is never set aside, re-proposed or
 * refiled under different words.
 */

type Supabase = ReturnType<typeof createAdminClient>;

export type FilingInput = {
  doc: {
    id: string;
    filename: string;
    client_id: string | null;
    state: string;
    kind: string;
    parsed: Json;
    proposal: Json;
    file_modified: string | null;
    storage_path: string | null;
  };
  text: string;
  fields: Record<string, string>;
  /** Set when `text` is Tesseract's reading of a scan. */
  ocr?: { confidence: number | null } | null;
};

export type FilingResult = {
  action: Plan["action"] | "skipped";
  detail: string;
  /**
   * The document was filed, and names an authorization that is not on file.
   * The paper is put away; somebody still has to decide whether an
   * authorization is owed, so the caller raises that once rather than per file.
   */
  needsAPerson?: boolean;
};

const asObject = (v: Json): Record<string, unknown> =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Record<string, unknown>) : {};

function summarize(plan: Plan): Json {
  const r = plan.reading;
  return {
    pattern: r.pattern,
    label: r.label,
    v_numbers: r.vNumbers,
    services: r.families,
    usor: r.usor,
    ...(plan.action === "propose"
      ? {
          named: plan.named,
          number: plan.number,
          service_type: plan.serviceType,
          why: plan.why,
          choices: plan.choices.map((a) => ({
            id: a.id,
            number: a.number,
            service_type: a.service_type,
            status: a.status,
            start_date: a.start_date,
            end_date: a.end_date,
          })),
        }
      : plan.action === "leave"
        ? { why: plan.why }
        : {}),
  } as Json;
}


/**
 * What to do with a document the name rules could not settle.
 *
 * Owner decision, 10 Oct 2026: clear the queue in bulk, no per-file questions.
 * Before this, a document the rules could only *propose* - an authorization or
 * an invoice whose number is not on file - waited in the inbox for somebody,
 * and 133 of them had been waiting. They are mostly paper for records that
 * already exist: 67 of the 79 waiting authorization documents belonged to
 * clients who already had authorizations.
 *
 * So the paper gets filed and the queue clears. What is deliberately *not*
 * done is decide anything about money: nothing here creates an authorization,
 * an invoice or an amount. A document named as an authorization that is not on
 * file is still a thing a person should look at, so it is filed **and** said
 * out loud (needsAPerson), rather than filed quietly or left waiting forever.
 *
 *   An invoice goes on the client's Paid authorization when exactly one of
 *   them is the obvious match - that is history, which is what the owner asked
 *   for - and otherwise on the client, because guessing which of three
 *   authorizations a scan belongs to is how a payment ends up against the
 *   wrong service.
 *
 *   Everything else goes to the client's Documents under the category the name
 *   suggests, or Other.
 *
 *   With no client it cannot be filed at all. It stays waiting and shows on
 *   the "Needs a person" list with its folder name.
 */
async function fileAsTheOwnerAsked(
  supabase: Supabase,
  doc: FilingInput["doc"],
  reading: NameReading,
  named: "Authorization" | "Invoice" | null,
  why: string,
): Promise<FilingResult> {
  const storagePath = doc.storage_path;
  if (!doc.client_id || !storagePath) {
    return { action: "leave", detail: `${why} — needs a person` };
  }

  const { data: meta } = await supabase
    .from("inbox_documents")
    .select("size_bytes")
    .eq("id", doc.id)
    .maybeSingle();

  // An invoice, on the one Paid authorization it can only be.
  let authId: string | null = null;
  if (named === "Invoice") {
    const { data: paid } = await supabase
      .from("authorizations")
      .select("id, service_type")
      .eq("client_id", doc.client_id)
      .eq("status", "Paid")
      .is("parent_id", null);
    const all = paid ?? [];
    const byService = reading.families.length
      ? all.filter((a) => reading.families.some((f: string) => (a.service_type ?? "").startsWith(f)))
      : [];
    if (byService.length === 1) authId = byService[0].id;
    else if (all.length === 1) authId = all[0].id;
  }

  const category: Category = named === "Invoice" ? "Invoice" : (reading.category ?? "Other");
  const note = authId
    ? "From the documents folder — kept as history against the paid authorization"
    : `From the documents folder — ${why}`;

  const { data: already } = await supabase
    .from("attachments")
    .select("id")
    .eq("storage_path", storagePath)
    .eq("client_id", doc.client_id)
    .limit(1);

  if (!already?.length) {
    const { error } = await supabase.from("attachments").insert({
      client_id: doc.client_id,
      storage_path: storagePath,
      filename: doc.filename,
      mime_type: "application/pdf",
      size_bytes: meta?.size_bytes ?? 0,
      category,
      auth_id: authId,
      note,
      uploaded_by_name: "Documents folder",
    });
    if (error) return { action: "leave", detail: `not attached: ${error.message}` };
  }

  const outcome = authId
    ? `Filed as ${category} against the paid authorization (${why})`
    : `Filed as ${category} on the client (${why})`;

  await supabase
    .from("inbox_documents")
    .update({ state: "Filed", decided_at: new Date().toISOString(), outcome })
    .eq("id", doc.id)
    .eq("state", "Pending");

  // An authorization nobody has on file is money that has not been entered.
  // Filed so the queue clears, and said so once so it is not lost with it.
  const needsAPerson = named === "Authorization";
  return {
    action: authId ? "link" : "attach",
    detail: outcome,
    needsAPerson,
  };
}

export async function fileByName(supabase: Supabase, input: FilingInput): Promise<FilingResult> {
  const { doc } = input;
  if (!doc.client_id) return { action: "skipped", detail: "no client for its folder yet" };
  if (!doc.storage_path) return { action: "skipped", detail: "no stored file" };

  const [{ data: client }, { data: auths }, { data: today }] = await Promise.all([
    supabase.from("clients").select("name").eq("id", doc.client_id).maybeSingle(),
    supabase.from("authorizations").select("id, client_id, number, service_type, status, start_date, end_date"),
    supabase.rpc("practice_today"),
  ]);

  const mine: AuthLite[] = (auths ?? []).filter((a) => a.client_id === doc.client_id);
  const elsewhere = (auths ?? []).filter((a) => a.client_id !== doc.client_id).map((a) => vKey(a.number));

  const parsed = asObject(doc.parsed);
  const fields = asObject(parsed.fields as Json) as Record<string, { value?: string }>;
  const usor = typeof parsed.usor === "string" ? (parsed.usor.match(/\d+/)?.[0] ?? null) : null;

  // An authorization's dates: from the stored reading, or read now from the
  // text - which, for a scan, is OCR. An OCR date is used only when both dates
  // read, both are real dates, the end is not before the start and the parser
  // raised no doubt about them; half a pair misread is worse than none.
  let authDates = { start: fields.startDate?.value || null, end: fields.endDate?.value || null };
  if (!authDates.start && !authDates.end && input.text.replace(/\s/g, "").length >= 40) {
    const read = parseAuthorizationText(input.text, { pages: 1, scanned: false });
    const start = read.fields.startDate?.value ?? null;
    const end = read.fields.endDate?.value ?? null;
    const doubtful = read.warnings.some((w) => /date/i.test(w));
    if (!input.ocr || (start && end && start <= end && !doubtful)) {
      authDates = { start, end };
    }
  }

  const plan = planDocument({
    filename: doc.filename,
    clientName: client?.name ?? "",
    fileModified: doc.file_modified,
    today: String(today ?? new Date().toISOString().slice(0, 10)),
    textKind: doc.kind,
    textUsor: usor,
    text: input.text,
    fields: input.fields,
    parsedAuth: authDates,
    ocr: input.ocr ?? null,
    auths: mine,
    numbersElsewhere: elsewhere,
  });

  const pending = doc.state === "Pending";
  const remember = async () => {
    if (!pending) return;
    await supabase
      .from("inbox_documents")
      .update({ proposal: { ...asObject(doc.proposal), filename: summarize(plan) } as Json })
      .eq("id", doc.id)
      .eq("state", "Pending");
  };

  switch (plan.action) {
    case "note": {
      const { data, error } = await supabase.rpc("file_document_as_note", {
        p_doc: doc.id,
        p_type: plan.noteType,
        p_at: plan.at,
        p_dated_from: plan.datedFrom,
        p_text: plan.text,
        p_category: plan.category,
        p_restricted: plan.restricted,
        p_outcome: plan.outcome,
        p_ocr: plan.fromOcr,
      });
      if (error) {
        await remember();
        return { action: "leave", detail: `note refused: ${error.message}` };
      }
      const row = Array.isArray(data) ? data[0] : null;
      return { action: "note", detail: `${row?.created ? "noted" : "already noted"}: ${plan.noteType}, ${plan.at} (${plan.datedFrom})` };
    }

    case "link": {
      const { data, error } = await supabase.rpc("link_document_to_authorization", {
        p_doc: doc.id,
        p_auth: plan.authId,
        p_category: plan.category,
        p_start: plan.start,
        p_end: plan.end,
        p_outcome: plan.outcome,
        p_ocr: plan.fromOcr,
      });
      if (error) {
        await remember();
        return { action: "leave", detail: `link refused: ${error.message}` };
      }
      const row = Array.isArray(data) ? data[0] : null;
      return {
        action: "link",
        detail: `${plan.category} on ${plan.authNumber}${row?.conflicts ? ` (dates differ: ${row.conflicts})` : ""}`,
      };
    }

    case "attach": {
      const { data: existing } = await supabase
        .from("attachments")
        .select("id")
        .eq("storage_path", doc.storage_path)
        .eq("client_id", doc.client_id)
        .limit(1);
      if (!existing?.length) {
        const { data: meta } = await supabase.from("inbox_documents").select("size_bytes").eq("id", doc.id).maybeSingle();
        const { error } = await supabase.from("attachments").insert({
          client_id: doc.client_id,
          storage_path: doc.storage_path,
          filename: doc.filename,
          mime_type: "application/pdf",
          size_bytes: meta?.size_bytes ?? 0,
          category: plan.category,
          note: "From the documents folder",
          uploaded_by_name: "Documents folder",
        });
        if (error) return { action: "leave", detail: `not attached: ${error.message}` };
      }
      if (pending) {
        await supabase
          .from("inbox_documents")
          .update({ state: "Filed", decided_at: new Date().toISOString(), outcome: plan.outcome })
          .eq("id", doc.id)
          .eq("state", "Pending");
      }
      return { action: "attach", detail: plan.outcome };
    }

    case "ignore": {
      if (!pending) return { action: "skipped", detail: "already decided" };
      await supabase
        .from("inbox_documents")
        .update({ state: "Ignored", decided_at: new Date().toISOString(), outcome: plan.reason })
        .eq("id", doc.id)
        .eq("state", "Pending");
      return { action: "ignore", detail: plan.reason };
    }

    case "propose":
      await remember();
      // Filed rather than left waiting (owner, 10 Oct 2026), and said out loud
      // when what it was named is an authorization nobody has on file.
      return fileAsTheOwnerAsked(supabase, doc, plan.reading, plan.named, plan.why);

    case "leave":
      await remember();
      return fileAsTheOwnerAsked(supabase, doc, plan.reading, null, plan.why);
  }
}
