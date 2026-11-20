"use server";

import { revalidatePath } from "next/cache";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { createAdminClient } from "@/lib/supabase/admin";
import { draftReport } from "@/lib/report-drafts";
import { reportTemplateFromForm } from "@/lib/report-shape";

export type BoardState = { error: string | null; ok: string | null };

/**
 * The three things the board itself changes.
 *
 * Everything else on it is a link to the screen that already does the work:
 * the period opens the report, the Signed pill opens the mail with the PDF
 * ticked, the week chip opens the week it is about. What is here is the two
 * cells that take input and the button that makes a report exist.
 *
 * None of these re-checks who may press it. The policy and `report_hands`
 * (0377) say who may change a report, they say it last, and where they refuse
 * the sentence they refuse with is what the screen shows - it was written to
 * be read by whoever hit it. The screen hides the controls it knows would be
 * refused, which is a courtesy and not the rule.
 */

const paths = (clientId: string) => {
  revalidatePath("/client-reports");
  revalidatePath(`/clients/${clientId}/reports`);
  revalidatePath("/my-day");
};

/** Who is writing it. Reports' and Admin's, which `report_hands` enforces. */
export async function setReportWriter(
  _prev: BoardState,
  formData: FormData,
): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("report_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const writer = String(formData.get("writer_id") ?? "");
  if (!id) return { error: "Assemble it before giving it a writer.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("client_reports")
    .update({ owner_id: writer || null })
    .eq("id", id)
    .select("id")
    .maybeSingle();
  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That report is not there any more.", ok: null };

  paths(clientId);
  return { error: null, ok: writer ? "Writer set" : "Writer cleared" };
}

/** When it is wanted by. The same hands as the writer. */
export async function setReportDue(
  _prev: BoardState,
  formData: FormData,
): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("report_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const due = String(formData.get("due_on") ?? "");
  if (!id) return { error: "Assemble it before giving it a date.", ok: null };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) return { error: "That date is not a date.", ok: null };

  const supabase = await createClient();
  const { data, error } = await supabase
    .from("client_reports")
    .update({ due_on: due })
    .eq("id", id)
    .select("id")
    .maybeSingle();
  if (error) return { error: error.message, ok: null };
  if (!data) return { error: "That report is not there any more.", ok: null };

  paths(clientId);
  return { error: null, ok: "Due date set" };
}

/**
 * A row nobody has started, started.
 *
 * The board's rows are built from the caseload rather than from the table
 * (0377), so a row can exist on screen with nothing behind it. This is the
 * button that puts something behind it, and it reads the record the way the
 * scheduler does - through `draftReport`, as the service role, for the reason
 * `redraftMonth` gives: a draft assembled seeing less than the scheduler sees
 * would be a shorter month for the same thirty-one days.
 *
 * The period is the row's own, never a date off the form, so there is no
 * "that month has not happened yet" to say: the board only has months it is
 * showing.
 */
export async function startReport(
  _prev: BoardState,
  formData: FormData,
): Promise<BoardState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const period = String(formData.get("period") ?? "");
  const template = reportTemplateFromForm(formData.get("template"));
  if (!clientId) return { error: "No client given.", ok: null };
  if (!template) return { error: "Choose which report.", ok: null };
  if (!/^\d{4}-\d{2}-01$/.test(period)) return { error: "A month starts on the first.", ok: null };

  const admin = createAdminClient();
  let done;
  try {
    done = await draftReport(admin, template, period, clientId);
  } catch (e) {
    return { error: e instanceof Error ? e.message : "It could not be assembled.", ok: null };
  }

  if (done.did === "left alone") {
    return { error: "That client is not Active or On hold, so no report is owed.", ok: null };
  }
  if (done.did === "frozen") {
    return { error: "That report is signed. Reopen it to assemble it again.", ok: null };
  }

  paths(clientId);
  return { error: null, ok: "Assembled" };
}
