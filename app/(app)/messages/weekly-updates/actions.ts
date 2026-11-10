"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { sendClientSms } from "@/lib/sms";

/**
 * The weekly update: approve it, change it, send it, or say why it is not
 * going (part B, 9 November 2026).
 *
 * "Nothing goes without a click" is the rule this file exists to keep. There
 * is no action here that sends an unapproved draft, and the one that sends
 * several sends the ones a person has already approved one at a time, so a
 * failure in the middle leaves the rest of them exactly where they were.
 *
 * Every send goes through `sendClientSms`, which is the door every other text
 * in the practice goes through: consent for that number, the 8am-9pm window
 * and a STOP are all enforced on `sms_messages` and none of them is restated
 * here. A refusal comes back in the database's own words.
 */

export type UpdateState = { error: string | null; ok: string | null };

const done = () => {
  revalidatePath("/messages/weekly-updates");
  revalidatePath("/messages/texts");
};

const refusal = (message: string) => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

export async function approveUpdate(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const { error } = await supabase.rpc("approve_weekly_update", {
    p_id: String(formData.get("id") ?? ""),
    p_approved: formData.get("approved") !== "no",
  });
  if (error) return refusal(error.message);
  done();
  return { error: null, ok: formData.get("approved") !== "no" ? "Approved." : "Back to a draft." };
}

export async function editUpdate(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const { error } = await supabase.rpc("edit_weekly_update", {
    p_id: String(formData.get("id") ?? ""),
    p_body: String(formData.get("body") ?? ""),
  });
  if (error) return refusal(error.message);
  done();
  return { error: null, ok: "Saved." };
}

export async function discardUpdate(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const { error } = await supabase.rpc("discard_weekly_update", {
    p_id: String(formData.get("id") ?? ""),
    p_reason: String(formData.get("reason") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done();
  return { error: null, ok: "Logged as not sent, with the reason." };
}

/** One approved update, sent. The only place in this file that sends anything. */
async function sendOne(
  supabase: Awaited<ReturnType<typeof createClient>>,
  staffId: string,
  id: string,
): Promise<{ ok: boolean; who: string; error?: string }> {
  const { data: row } = await supabase
    .from("weekly_updates")
    .select("id, client_id, contact_id, phone, body, state")
    .eq("id", id)
    .maybeSingle();
  if (!row) return { ok: false, who: "that update", error: "It is not there any more." };
  if (row.state !== "Approved") {
    return { ok: false, who: "that update", error: `It is ${row.state.toLowerCase()}, not approved.` };
  }

  const [{ data: client }, { data: contact }] = await Promise.all([
    supabase.from("clients").select("name, ghl_id").eq("id", row.client_id).maybeSingle(),
    row.contact_id
      ? supabase.from("client_contacts").select("name, relationship").eq("id", row.contact_id).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);
  const who = contact ? `${contact.name} (${contact.relationship})` : (client?.name ?? "the client");
  if (!row.phone) return { ok: false, who, error: "There is no number to send it to." };

  const outcome = await sendClientSms(supabase, {
    clientId: row.client_id,
    clientName: client?.name ?? "",
    phone: row.phone,
    body: row.body,
    kind: "Weekly update",
    staffId,
    // A contact is reached under their own name, and their provider contact
    // is never remembered as the client's (0332).
    recipientName: contact?.name ?? null,
    rememberOnClient: !row.contact_id,
    ghlId: row.contact_id ? null : (client?.ghl_id ?? null),
  });
  if (!outcome.ok) return { ok: false, who, error: outcome.error };

  const { error: markError } = await supabase.rpc("weekly_update_sent", {
    p_id: id,
    p_sms: outcome.id ?? "",
  });
  if (markError) {
    return {
      ok: false,
      who,
      error: `The text went, but the record of it did not save. ${markError.message}`,
    };
  }
  return { ok: true, who };
}

export async function sendUpdate(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const outcome = await sendOne(supabase, me.id, String(formData.get("id") ?? ""));
  done();
  if (!outcome.ok) return { error: `${outcome.who}: ${outcome.error}`, ok: null };
  return { error: null, ok: `Sent to ${outcome.who}.` };
}

/**
 * Everything already approved, one at a time.
 *
 * One click, which the owner asked for by name, and still one send per
 * person: a batch that stopped at the first refusal would leave a person
 * guessing which of thirty went. What comes back says how many went and names
 * the ones that did not.
 */
export async function sendApprovedUpdates(
  _prev: UpdateState,
  formData: FormData,
): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const week = String(formData.get("week") ?? "");
  const supabase = await createClient();

  const { data: rows } = await supabase
    .from("weekly_updates")
    .select("id")
    .eq("week_start", week)
    .eq("state", "Approved");

  const ids = (rows ?? []).map((r) => r.id);
  if (ids.length === 0) return { error: "Nothing is approved and waiting.", ok: null };

  let sent = 0;
  const failures: string[] = [];
  for (const id of ids) {
    const outcome = await sendOne(supabase, me.id, id);
    if (outcome.ok) sent += 1;
    else failures.push(`${outcome.who}: ${outcome.error}`);
  }
  done();

  const went = `${sent} of ${ids.length} sent.`;
  if (failures.length === 0) return { error: null, ok: went };
  return { error: `${went} ${failures.join(" ")}`, ok: null };
}

/**
 * Draft this week now.
 *
 * The sweep runs on a Friday afternoon, which is the right time and not the
 * only one: a Friday the cron missed leaves a week with no drafts, and a
 * person wanting to read the wording before Friday has nothing to read. It is
 * the same function the sweep calls, it is safe to run twice - a draft that
 * exists is left alone, edits and all - and it sends nothing.
 */
export async function draftThisWeek(_prev: UpdateState, formData: FormData): Promise<UpdateState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("draft_weekly_updates", {
    p_week_start: String(formData.get("week") ?? ""),
  });
  if (error) return refusal(error.message);
  done();
  const made = Number(data ?? 0);
  return {
    error: null,
    ok: made === 0 ? "They were all drafted already." : `${made} drafted. Nothing has been sent.`,
  };
}
