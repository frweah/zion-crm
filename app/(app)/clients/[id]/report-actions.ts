"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { sendEmail } from "@/lib/email";
import { today } from "@/lib/constants";
import { buildReportText, presetByKey, type ReportPeriod } from "@/lib/report";

export type SendReportState = { error: string | null; ok: string | null };

/**
 * Email a progress report to the counselor.
 *
 * The body is built here rather than taken from the page, so what leaves the
 * building is the record as the database has it and not whatever a browser
 * posted back. The narrative is the exception — those are the writer's own
 * words, and they are saved to the client's notes at the same time. Without
 * that, the only account of what was said about a client would be sitting in
 * a counselor's inbox.
 *
 * Nothing is marked sent unless Resend accepted it, for the same reason a form
 * is not: a report the counselor never received must not look like one they
 * did.
 */
export async function sendReport(
  _prev: SendReportState,
  formData: FormData,
): Promise<SendReportState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const kind: ReportPeriod = formData.get("kind") === "Monthly" ? "Monthly" : "Weekly";
  const preset = presetByKey(String(formData.get("preset") ?? ""));
  const start = String(formData.get("start") ?? "");
  const end = String(formData.get("end") ?? "");
  const narrative = String(formData.get("narrative") ?? "").trim();
  const to = String(formData.get("to") ?? "").trim();

  if (!/^\d{4}-\d{2}-\d{2}$/.test(start) || !/^\d{4}-\d{2}-\d{2}$/.test(end)) {
    return { error: "That reporting period does not look right.", ok: null };
  }
  if (!to) {
    return {
      error: "This client has no counselor email address on file. Add one on the Overview tab.",
      ok: null,
    };
  }

  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select("id, name, client_no, agency_id, counselor_id")
    .eq("id", clientId)
    .maybeSingle();

  if (!client) return { error: "Client not found.", ok: null };

  const { data: counselor } = client.counselor_id
    ? await supabase
        .from("counselors")
        .select("id, name, email")
        .eq("id", client.counselor_id)
        .maybeSingle()
    : { data: null };

  // The address comes from the record, not from the form — a report is one of
  // the few things here that leaves the building, and it should only ever go
  // to the counselor the client is assigned to.
  if (counselor?.email && counselor.email.trim().toLowerCase() !== to.toLowerCase()) {
    return {
      error: `That address is not ${counselor.name}'s. Reports go to the counselor on the record.`,
      ok: null,
    };
  }

  const { text } = await buildReportText(clientId, kind, start, end, preset.key);
  const body = narrative ? `${text}\n\nNARRATIVE\n${narrative}` : text;

  const subject = `${preset.label} — ${client.name}${
    client.agency_id ? ` (USOR ID ${client.agency_id})` : ""
  } — ${start} to ${end}`;

  const result = await sendEmail({ to, subject, text: body });
  if (!result.ok) return { error: `Not sent. ${result.error}`, ok: null };

  await supabase.from("contact_log").insert({
    counselor_id: counselor?.id ?? null,
    client_id: clientId,
    date: today(),
    method: "Report sent",
    topic: `${preset.label} (${kind.toLowerCase()}, ${start} to ${end})`,
    outcome: `Emailed to ${to}`,
    staff_id: me.id,
  });

  if (narrative) {
    await supabase.from("notes").insert({
      client_id: clientId,
      staff_id: me.id,
      staff_name: me.name,
      type: "Counselor contact",
      text: `${preset.label} sent to ${counselor?.name ?? to}:\n\n${narrative}`,
      visible_roles: ["Admin", "Job Search", "Reports", "Billing"],
    });
  }

  revalidatePath(`/clients/${clientId}`);
  revalidatePath("/counselors");

  return {
    error: null,
    ok: `Sent to ${to}, logged in the counselor contact log${
      narrative ? ", and the narrative saved to notes" : ""
    }.`,
  };
}
