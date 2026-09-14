import "server-only";
import type { createAdminClient } from "@/lib/supabase/admin";
import { planDocument, vKey, type AuthLite, type Plan } from "@/lib/filename-rules";
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
};

export type FilingResult = { action: Plan["action"] | "skipped"; detail: string };

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

  const plan = planDocument({
    filename: doc.filename,
    clientName: client?.name ?? "",
    fileModified: doc.file_modified,
    today: String(today ?? new Date().toISOString().slice(0, 10)),
    textKind: doc.kind,
    textUsor: usor,
    text: input.text,
    fields: input.fields,
    parsedAuth: { start: fields.startDate?.value || null, end: fields.endDate?.value || null },
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
      return { action: "propose", detail: `${plan.named}: ${plan.why}` };

    case "leave":
      await remember();
      return { action: "leave", detail: plan.why };
  }
}
