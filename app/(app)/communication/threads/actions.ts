"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { sendClientText } from "@/lib/sms";
import { CAN_SEND_TEXTS, CAN_LOG_CALLS } from "@/lib/threads-board-shape";
import { noteCategoryFromForm } from "@/lib/report-shape";

/**
 * What a person can do from a client thread.
 *
 * Nothing here decides whether a text may go: the database does, on the way
 * in - the number has to be on the record, that number has to have agreed,
 * and the clock has to be inside 8am to 9pm. Every refusal comes back in the
 * database's own words and this screen passes it through.
 *
 * The role checks below are not the rule either. The rule is the policy on
 * `sms_messages`, which admits Admin, Job Search and Reports. These are here
 * so that a role the policy will refuse is told in a sentence rather than
 * shown a box and a row-level error (ruling 6c).
 */
export type ThreadState = { error: string | null; ok: string | null };

const done = (clientId?: string | null) => {
  revalidatePath("/communication/threads");
  revalidatePath("/messages/texts");
  if (clientId) revalidatePath(`/clients/${clientId}`);
};

/** The database's sentence, without the plpgsql furniture in front of it. */
const refusal = (message: string): ThreadState => ({
  error: message.replace(/^.*?:\s*/, "").trim() || message,
  ok: null,
});

/** Who is answering this thread. `assign_conversation` decides who may. */
export async function assignThread(_prev: ThreadState, formData: FormData): Promise<ThreadState> {
  const supabase = await createClient();
  const staff = String(formData.get("staff_id") ?? "");
  const { error } = await supabase.rpc("assign_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_staff: staff === "" ? null : staff,
  });
  if (error) return refusal(error.message);
  done(String(formData.get("client_id") ?? "") || null);
  return { error: null, ok: "Assigned." };
}

/**
 * A text, to the number that was chosen on the panel.
 *
 * The number is passed rather than looked up, because a client thread folds
 * several in and the one to answer is the one the message came from. It is
 * still checked - against the record and against that number's own consent -
 * by the trigger on `sms_messages`, so a number from a stale page is refused
 * rather than sent to.
 */
export async function sendOnThread(_prev: ThreadState, formData: FormData): Promise<ThreadState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  if (!CAN_SEND_TEXTS.includes(me.role)) {
    return { error: "Your role does not send texts. Log the call instead.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "");
  const phone = String(formData.get("phone") ?? "").trim();
  const body = String(formData.get("body") ?? "").trim();
  const later = formData.get("later") === "yes";
  if (!phone) return { error: "There is no number to send to.", ok: null };
  if (!body) return { error: "The message is empty.", ok: null };
  if (body.length > 600) return { error: "That is too long for a text - 600 characters at most.", ok: null };

  const supabase = await createClient();
  const [{ data: client }, { data: window }] = await Promise.all([
    supabase.from("clients").select("name, ghl_id").eq("id", clientId).maybeSingle(),
    supabase.rpc("next_text_window", { p_at: new Date().toISOString() }),
  ]);
  if (!client) return { error: "That client is not on file.", ok: null };

  // Whose number this is, so a contact is reached under their own name and
  // their provider contact is never remembered as the client's (0332).
  const { data: contact } = await supabase
    .from("client_contacts")
    .select("name")
    .eq("client_id", clientId)
    .eq("phone", phone)
    .maybeSingle();

  const outcome = await sendClientText(supabase, {
    clientId,
    clientName: client.name,
    phone,
    body,
    kind: "Manual",
    staffId: me.id,
    recipientName: contact?.name ?? null,
    rememberOnClient: !contact,
    ghlId: contact ? null : (client.ghl_id ?? null),
    sendAfter: later ? (window as string | null) : null,
  });

  done(clientId);
  if (!outcome.ok) return refusal(outcome.error);
  return {
    error: null,
    ok: later ? "Written. It goes out when the window opens." : "Sent.",
  };
}

/**
 * A call, written down (Part 3).
 *
 * One function in the database writes both halves - the note that says what
 * was said, and the contact-log line the month counts - so a call cannot end
 * up half-recorded.
 */
export async function logCall(_prev: ThreadState, formData: FormData): Promise<ThreadState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };
  if (!CAN_LOG_CALLS.includes(me.role)) {
    return { error: "Your role does not write on a client's record.", ok: null };
  }

  const clientId = String(formData.get("client_id") ?? "");
  const text = String(formData.get("text") ?? "").trim();
  if (!text) return { error: "Say what the call was about.", ok: null };

  const category = noteCategoryFromForm(formData.get("category"));
  if (!category) return { error: "Say which service the call was about.", ok: null };

  const when = String(formData.get("on") ?? "").trim();
  const supabase = await createClient();
  const { error } = await supabase.rpc("log_a_call", {
    p_client: clientId,
    p_text: text,
    p_category: category,
    p_on: /^\d{4}-\d{2}-\d{2}$/.test(when) ? when : null,
    p_outcome: String(formData.get("outcome") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(clientId);
  revalidatePath("/client-reports");
  return { error: null, ok: "The call is on the record and in the month." };
}

/**
 * This message, on the client's month.
 *
 * A contact-log line dated when the thing happened, which is what the reports
 * board counts and what a monthly report reads. Not the words - the message
 * stays where it is.
 */
export async function addToReport(_prev: ThreadState, formData: FormData): Promise<ThreadState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase.rpc("collect_contact", {
    p_channel: String(formData.get("channel") ?? ""),
    p_ref: String(formData.get("ref") ?? ""),
    p_note: String(formData.get("note") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done(String(formData.get("client_id") ?? "") || null);
  revalidatePath("/client-reports");
  return { error: null, ok: "On the month." };
}

/** A website chat, answered where it is read. The same door the inbox uses. */
export async function replyOnWeb(_prev: ThreadState, formData: FormData): Promise<ThreadState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("post_web_reply", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_body: String(formData.get("body") ?? "").trim(),
  });
  if (error) return refusal(error.message);
  done();
  return { error: null, ok: "Sent." };
}
