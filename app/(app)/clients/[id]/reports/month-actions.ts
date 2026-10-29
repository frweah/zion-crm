"use server";

import { revalidatePath } from "next/cache";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { keepAttachmentOnClient } from "@/lib/mail-filing";
import { buildMonthContent, draftMonth, type MonthlyContent } from "@/lib/report-drafts";
import { monthlyReportPdf } from "@/lib/report-pdf";
import { type MonthlyMeta } from "@/lib/report-text";
import { signatureFor } from "@/lib/staff-signature";
import { today } from "@/lib/constants";

export type MonthState = { error: string | null; ok: string | null };

/**
 * A month, as the person who signs it changes it.
 *
 * The order the month goes in is the database's (0260): Draft, Reviewed,
 * Signed, Sent, and a trigger refuses anything else. Nothing here re-checks
 * what that trigger already checks - where it refuses, the sentence it
 * refuses with goes straight to the screen, because it was written to be read
 * by whoever hit it. What is here is the work the database cannot do:
 * building the PDF, putting it on the client's record, and deciding which
 * staff member's signature goes over which name.
 *
 * Signing is the irreversible-looking step and is therefore the one with the
 * most said about it below.
 */

async function row(formData: FormData) {
  const me = await getCurrentStaff();
  return {
    me,
    id: String(formData.get("month_id") ?? ""),
    clientId: String(formData.get("client_id") ?? ""),
  };
}

const paths = (clientId: string, month: string) => {
  revalidatePath(`/clients/${clientId}/reports`);
  revalidatePath(`/clients/${clientId}/reports/${month}`);
  revalidatePath("/my-day");
};

/** The summary, in the owner's own words. The one part of the report nobody else wrote. */
export async function saveMonthSummary(
  _prev: MonthState,
  formData: FormData,
): Promise<MonthState> {
  const { me, id, clientId } = await row(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("client_monthly_reports")
    .update({ note: String(formData.get("note") ?? "").trim() })
    .eq("id", id)
    .select("month")
    .maybeSingle();
  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That month is not yours to change.", ok: null };

  paths(clientId, data.month);
  return { error: null, ok: "Saved" };
}

/** Read, and ready to sign. */
export async function reviewMonth(_prev: MonthState, formData: FormData): Promise<MonthState> {
  const { me, id, clientId } = await row(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("client_monthly_reports")
    .update({
      note: String(formData.get("note") ?? "").trim(),
      status: "Reviewed",
      reviewed_at: new Date().toISOString(),
      reviewed_by: me.id,
    })
    .eq("id", id)
    .select("month")
    .maybeSingle();
  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That month is not yours to change.", ok: null };

  paths(clientId, data.month);
  return { error: null, ok: "Reviewed" };
}

/** Read the weeks again. Draft only, because a reviewed month has been read. */
export async function redraftMonth(_prev: MonthState, formData: FormData): Promise<MonthState> {
  const { me, id, clientId } = await row(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data: month } = await supabase
    .from("client_monthly_reports")
    .select("id, month, status")
    .eq("id", id)
    .maybeSingle();
  if (!month) return { error: "That month is not yours to change.", ok: null };
  if (month.status !== "Draft") {
    return { error: "Reopen the month before assembling it again.", ok: null };
  }

  // The service role, for the reason redraftWeek uses it: the scheduler
  // assembles these seeing everything, and a redraft that saw less would
  // quietly produce a shorter month for the same thirty-one days.
  const admin = createAdminClient();
  const content = await buildMonthContent(admin, clientId, month.month);
  const { error } = await supabase
    .from("client_monthly_reports")
    .update({ content: content as never, generated_at: new Date().toISOString() })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  paths(clientId, month.month);
  return { error: null, ok: "Assembled again from the weeks" };
}

/**
 * Sign it, which is what makes it a document.
 *
 * Three things happen and the order matters. The PDF is built from the
 * content on the row — not from the record as it is now — so what is signed
 * is what was on the screen. It is filed on the client as an ordinary
 * attachment, so it is in the client's documents, in a records request, and
 * in the places a document is looked for, rather than only reachable from
 * here. Then the row is stamped and points at that attachment.
 *
 * The stamp is last on purpose. A row that says Signed and names no PDF is a
 * report nobody can check against what the counselor received, and 0260
 * refuses to send one; a PDF filed against a row that was never stamped is a
 * document somebody can see is a draft. Of the two ways this can be
 * interrupted, the second is the one that leaves the record honest.
 *
 * The signature image is the signer's own, fetched by the id of the person
 * signing now, which for a report is always the person pressing the button.
 */
export async function signMonth(_prev: MonthState, formData: FormData): Promise<MonthState> {
  const { me, id, clientId } = await row(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { data: month } = await supabase
    .from("client_monthly_reports")
    .select("id, month, status, content, note, pdf_attachment_id")
    .eq("id", id)
    .maybeSingle();
  if (!month) return { error: "That month is not yours to sign.", ok: null };
  if (month.status === "Sent") {
    return { error: "That report has already gone to the counselor.", ok: null };
  }
  if (month.status === "Signed") {
    return { error: "That report is signed. Reopen it to change it.", ok: null };
  }

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, client_no, agency_id, counselor_id")
    .eq("id", clientId)
    .maybeSingle();
  if (!client) return { error: "Client not found.", ok: null };

  const { data: counselor } = client.counselor_id
    ? await supabase.from("counselors").select("name").eq("id", client.counselor_id).maybeSingle()
    : { data: null };

  const content = (month.content ?? {}) as unknown as MonthlyContent;
  const at = new Date();
  const meta: MonthlyMeta = {
    clientName: client.name,
    clientNo: client.client_no,
    agencyId: client.agency_id,
    counselorName: counselor?.name ?? null,
    ownerName: me.name,
    summary: month.note ?? "",
    signedBy: me.name,
    signedAt: at.toISOString(),
  };

  let pdf;
  try {
    pdf = await monthlyReportPdf({
      month: month.month,
      content,
      meta,
      signature: { name: me.name, at, image: await signatureFor(me.id) },
    });
  } catch (e) {
    return {
      error: e instanceof Error ? e.message : "The report could not be made into a PDF.",
      ok: null,
    };
  }

  const stamp = new Date(`${month.month}T12:00:00Z`).toLocaleDateString("en-US", {
    month: "long",
    year: "numeric",
  });
  const filed = await keepAttachmentOnClient({
    clientId,
    filename: `Monthly report ${client.name} ${stamp}.pdf`.replace(/[\/:*?"<>|]/g, "-"),
    mime: "application/pdf",
    data: Buffer.from(pdf.bytes),
    category: "Monthly report",
    restricted: false,
    note: `Signed by ${me.name}.`,
  });
  if (filed.error || !filed.id) {
    return { error: filed.error ?? "The report was not filed on the client.", ok: null };
  }

  const { error } = await supabase
    .from("client_monthly_reports")
    .update({
      status: "Signed",
      signed_at: at.toISOString(),
      signed_by: me.id,
      pdf_attachment_id: filed.id,
      reopen_reason: "",
    })
    .eq("id", id);
  if (error) return { error: error.message, ok: null };

  paths(clientId, month.month);
  revalidatePath(`/clients/${clientId}`);
  return { error: null, ok: "Signed, and the PDF is on the client's documents" };
}

/**
 * Take a signed report back, saying why.
 *
 * The reason is kept on the row (0260) and is not optional there, so this
 * asks for it rather than letting the database refuse an empty one. Reopening
 * also releases the weeks the month had frozen, which is the point: a signed
 * PDF whose own weeks no longer add up to it is worse than either version
 * alone, so the only way to change a week is to reopen the month it is part
 * of and own that.
 *
 * A sent report cannot be reopened at all. What the counselor was told does
 * not change after they were told it; a correction is a new month's report or
 * a letter, both of which leave a trace.
 */
export async function reopenMonth(_prev: MonthState, formData: FormData): Promise<MonthState> {
  const { me, id, clientId } = await row(formData);
  if (!me) return { error: "You are not signed in.", ok: null };

  const reason = String(formData.get("reason") ?? "").trim();
  if (!reason) return { error: "Say why it is being reopened.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("client_monthly_reports")
    .update({
      status: "Draft",
      signed_at: null,
      signed_by: null,
      reviewed_at: null,
      reviewed_by: null,
      reopen_reason: reason,
      reopened_by: me.id,
    })
    .eq("id", id)
    .select("month")
    .maybeSingle();
  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That month is not yours to reopen.", ok: null };

  paths(clientId, data.month);
  return { error: null, ok: "Reopened, and its weeks can be changed again" };
}

/**
 * A month the scheduler never assembled, assembled now.
 *
 * The same thing `makeWeek` is for: a client taken on mid-month, or a month
 * somebody wants before the 1st. Done the way the scheduler does it.
 */
export async function makeMonth(_prev: MonthState, formData: FormData): Promise<MonthState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const month = String(formData.get("month") ?? "");
  if (!/^\d{4}-\d{2}-01$/.test(month)) {
    return { error: "A month starts on the first.", ok: null };
  }
  if (month > today()) {
    return { error: "That month has not happened yet.", ok: null };
  }

  const admin = createAdminClient();
  try {
    const done = await draftMonth(admin, month, [clientId]);
    if (!done.length) {
      return { error: "That client is not Active or On hold, so no report is owed.", ok: null };
    }
    if (done[0].did === "frozen") {
      return { error: "That month is signed. Reopen it to assemble it again.", ok: null };
    }
  } catch (e) {
    return { error: e instanceof Error ? e.message : "The month could not be assembled.", ok: null };
  }

  paths(clientId, month);
  return { error: null, ok: "Assembled" };
}
