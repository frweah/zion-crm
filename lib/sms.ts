import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { findContactByPhone, upsertContact, sendSms as ghlSend } from "@/lib/ghl";

/**
 * Sending a text, in the order that keeps the record honest.
 *
 * The row is written first. That is not bookkeeping — the database refuses to
 * write an outgoing message to a client who has not agreed to be texted, so
 * writing it down is the permission check, and it happens before anything
 * reaches a carrier. A send path that called the API first and recorded it
 * afterwards would have already texted somebody by the time it found out it
 * should not have.
 *
 * Then it sends, then it marks the row Sent or Failed. A Failed row keeps the
 * attempt visible and leaves the way open for another try — the "one reminder
 * per appointment" index counts everything except failures.
 */

export type SendResult =
  | { ok: true; id: string }
  | { ok: false; error: string; recorded: boolean };

/** What a day-before reminder says. */
export function reminderText(params: {
  clientName: string;
  day: string;
  time: string;
  kind: string;
}): string {
  const first = params.clientName.trim().split(/\s+/)[0] || "Hello";
  // Short, no link, no marketing, and it says who it is from — a reminder
  // somebody cannot place is a reminder they ignore.
  //
  // No opt-out line here. The sub-account appends its own — "STOP / Thanks,
  // Zion Voc Rehab" — and a message carrying two of them reads like a form
  // letter and costs a second segment. That makes this a dependency worth
  // knowing about: if that setting is ever turned off in GoHighLevel, these
  // messages go out with no opt-out notice at all, which is not allowed.
  // Whoever changes it puts the sentence back here.
  return (
    `Hi ${first}, a reminder from Zion Vocational Rehab: you have ${
      /^[aeiou]/i.test(params.kind) ? "an" : "a"
    } ${params.kind.toLowerCase()} tomorrow, ${params.day} at ${params.time}. ` +
    `Call 385-406-3432 if you need to change it.`
  );
}

export async function sendClientSms(
  supabase: SupabaseClient<Database>,
  params: {
    clientId: string;
    clientName: string;
    phone: string;
    body: string;
    kind: "Reminder" | "Manual" | "System";
    eventId?: string | null;
    staffId?: string | null;
    ghlId?: string | null;
  },
): Promise<SendResult> {
  // ── the permission check, which is also the record ─────────
  const { data: row, error: insertError } = await supabase
    .from("sms_messages")
    .insert({
      client_id: params.clientId,
      direction: "Outgoing",
      phone: params.phone,
      body: params.body,
      kind: params.kind,
      event_id: params.eventId ?? null,
      status: "Queued",
      created_by: params.staffId ?? null,
    })
    .select("id")
    .single();

  if (insertError || !row) {
    return {
      ok: false,
      error: insertError?.message ?? "The message could not be recorded, so it was not sent.",
      recorded: false,
    };
  }

  const fail = async (error: string): Promise<SendResult> => {
    await supabase
      .from("sms_messages")
      .update({ status: "Failed", error: error.slice(0, 300) })
      .eq("id", row.id);
    return { ok: false, error, recorded: true };
  };

  // ── who to send it to ──────────────────────────────────────
  let contactId = params.ghlId ?? null;

  if (!contactId) {
    const found = await findContactByPhone(params.phone);
    if (!found.ok) return fail(found.error);
    contactId = found.data;
  }

  if (!contactId) {
    const made = await upsertContact({ phone: params.phone, name: params.clientName });
    if (!made.ok) return fail(made.error);
    contactId = made.data;

    // Remember it, so the next text is one call instead of three.
    await supabase.from("clients").update({ ghl_id: contactId }).eq("id", params.clientId);
  }

  const sent = await ghlSend({ contactId, message: params.body });
  if (!sent.ok) return fail(sent.error);

  await supabase
    .from("sms_messages")
    .update({
      status: "Sent",
      sent_at: new Date().toISOString(),
      provider_message_id: sent.data || null,
    })
    .eq("id", row.id);

  return { ok: true, id: row.id };
}

/**
 * Tomorrow's reminders.
 *
 * The view decides who is due — consent, the right number, tomorrow in Utah's
 * day rather than the server's, and nothing already sent. This just walks it.
 */
export async function sendDueReminders(
  supabase: SupabaseClient<Database>,
): Promise<{ sent: number; failed: number; skipped: number; errors: string[] }> {
  const result = { sent: 0, failed: 0, skipped: 0, errors: [] as string[] };

  const { data: due, error } = await supabase
    .from("sms_due_reminders")
    .select("event_id, client_id, client_name, phone, kind, local_day, local_time");

  if (error) {
    result.errors.push(error.message);
    return result;
  }

  for (const r of due ?? []) {
    if (!r.client_id || !r.phone || !r.event_id) {
      result.skipped += 1;
      continue;
    }

    const { data: client } = await supabase
      .from("clients")
      .select("ghl_id")
      .eq("id", r.client_id)
      .maybeSingle();

    const outcome = await sendClientSms(supabase, {
      clientId: r.client_id,
      clientName: r.client_name ?? "",
      phone: r.phone,
      body: reminderText({
        clientName: r.client_name ?? "",
        day: r.local_day ?? "tomorrow",
        time: r.local_time ?? "",
        kind: r.kind ?? "appointment",
      }),
      kind: "Reminder",
      eventId: r.event_id,
      ghlId: client?.ghl_id ?? null,
    });

    if (outcome.ok) {
      result.sent += 1;
    } else {
      result.failed += 1;
      result.errors.push(`${r.client_name}: ${outcome.error}`);
    }
  }

  return result;
}
