import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { findContactByPhone, upsertContact, sendSms as ghlSend, messageStatus } from "@/lib/ghl";

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
  // No opt-out line here. The GoHighLevel sub-account appends its own —
  // "STOP / Thanks, Zion Voc Rehab" — and two of them in one text reads like
  // a form letter.
  //
  // It is not appended to every message. The sub-account has periodic opt-out
  // switched on, so it goes on the first message to a contact and then once
  // every thirty days. Most reminders therefore carry no STOP line, which is
  // the intended pattern rather than a gap: the notice belongs in the first
  // message and periodically after it, and STOP works whether or not the line
  // is showing — the carrier honours it, and our webhook records it and
  // withdraws consent.
  //
  // That makes the notice a setting in somebody else's system. If periodic
  // opt-out is ever turned off in GoHighLevel, nothing carries it at all and
  // the sentence comes back here.
  return (
    `Hi ${first}, a reminder from Zion Voc Rehab: you have ${
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
    kind: "Reminder" | "Manual" | "System" | "Weekly update";
    eventId?: string | null;
    staffId?: string | null;
    ghlId?: string | null;
    /**
     * Whose number this is, where it is not the client's own (0332).
     *
     * A client's partner has their own number, and a text to it is still the
     * client's record - but the provider needs a contact, and a contact
     * created under the client's name with somebody else's number is a
     * mislabelled person in a system this practice does not control.
     *
     * `rememberOnClient` is the half that matters more. The client's
     * provider-contact id is cached on `clients.ghl_id` so the next text is
     * one call instead of three; caching a *contact's* id there would send
     * the client's own next text to their partner's phone.
     */
    recipientName?: string | null;
    rememberOnClient?: boolean;
    /**
     * Written now, sent then (0105). The gate still decides: consent, the
     * right number, and a time inside 8am-9pm. Nothing is sent here - the
     * cron picks it up when the window opens.
     */
    sendAfter?: string | null;
  },
): Promise<SendResult> {
  // ── the permission check, which is also the record ─────────
  const scheduled = Boolean(params.sendAfter);
  const { data: row, error: insertError } = await supabase
    .from("sms_messages")
    .insert({
      client_id: params.clientId,
      direction: "Outgoing",
      phone: params.phone,
      body: params.body,
      kind: params.kind,
      event_id: params.eventId ?? null,
      status: scheduled ? "Scheduled" : "Queued",
      send_after: params.sendAfter ?? null,
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

  // Through the database's own function, not a direct update. `sms_messages`
  // carries a restrictive UPDATE policy and nothing permissive, so a direct
  // update from a signed-in staff member matched no rows and reported
  // success - which is how every text a person sent from a screen stayed on
  // 'Queued' while the client had it in their hand (0285).
  const fail = async (error: string): Promise<SendResult> => {
    await supabase.rpc("record_text_failed", { p_id: row.id, p_error: error.slice(0, 300) });
    return { ok: false, error, recorded: true };
  };

  // Scheduled: recorded, and that is all for now.
  if (scheduled) return { ok: true, id: row.id };

  // ── who to send it to ──────────────────────────────────────
  let contactId = params.ghlId ?? null;

  if (!contactId) {
    const found = await findContactByPhone(params.phone);
    if (!found.ok) return fail(found.error);
    contactId = found.data;
  }

  if (!contactId) {
    const made = await upsertContact({
      phone: params.phone,
      name: params.recipientName?.trim() || params.clientName,
    });
    if (!made.ok) return fail(made.error);
    contactId = made.data;

    // Remember it, so the next text is one call instead of three - and only
    // when the number is the client's own. See rememberOnClient above: this
    // line with a contact's number in it would point the client's own
    // messages at their partner's phone.
    if (params.rememberOnClient !== false) {
      await supabase.from("clients").update({ ghl_id: contactId }).eq("id", params.clientId);
    }
  }

  const sent = await ghlSend({ contactId, message: params.body });
  if (!sent.ok) return fail(sent.error);

  const { error: recordError } = await supabase.rpc("record_text_sent", {
    p_id: row.id,
    p_provider_id: sent.data || null,
  });
  // The text has gone. If recording that fails, say so rather than reporting
  // a clean send: a row left on 'Queued' is what somebody will try to send
  // again.
  if (recordError) {
    return {
      ok: false,
      error: `The text went, but the record of it did not save. ${recordError.message}`,
      recorded: true,
    };
  }

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

/**
 * Texts written for the next window (0105), now that it is open.
 *
 * Each one goes through the same send as any other, and the gate is asked
 * again on the way: consent withdrawn overnight means it does not go.
 */
export async function sendScheduledTexts(
  supabase: SupabaseClient<Database>,
): Promise<{ sent: number; failed: number; errors: string[] }> {
  const result = { sent: 0, failed: 0, errors: [] as string[] };

  // Anything a run that died left claimed comes back first, or it would sit
  // in Sending for good and never be sent (0209).
  await supabase.rpc("release_stale_text_claims");

  const { data: due, error } = await supabase
    .from("sms_messages")
    .select("id")
    .eq("status", "Scheduled")
    .lte("send_after", new Date().toISOString())
    .limit(100);
  if (error) {
    result.errors.push(error.message);
    return result;
  }

  for (const found of due ?? []) {
    /**
     * Taken before it is sent, not after.
     *
     * Two runs overlapping — Vercel cron delivers at least once, and the
     * curl command in the route's own comment can be run alongside the
     * schedule — both used to read this row and both used to send it. The
     * conditional update is the lock: Postgres serialises the two on the
     * row and only one of them finds it still Scheduled. Whoever loses skips
     * it rather than sending a second copy to the client.
     */
    const { data: claimedRows } = await supabase.rpc("claim_scheduled_text", { p_id: found.id });
    const row = claimedRows?.[0];
    if (!row) continue;

    // A function's output columns are nullable to the type generator, and a
    // text with no number or no words could not be sent anyway.
    const { id, client_id: clientId, phone, body } = row;
    if (!id || !clientId || !phone || !body) continue;

    const { data: client } = await supabase
      .from("clients")
      .select("name, ghl_id")
      .eq("id", clientId)
      .maybeSingle();

    // Sent as a new message and the scheduled one closed, so the gate runs
    // again rather than being remembered from last night.
    const outcome = await sendClientSms(supabase, {
      clientId,
      clientName: client?.name ?? "",
      phone,
      body,
      kind: "Manual",
      staffId: row.created_by,
      ghlId: client?.ghl_id ?? null,
    });

    if (outcome.ok) {
      await supabase.rpc("cancel_scheduled_text", { p_id: id });
      result.sent += 1;
    } else {
      await supabase.rpc("record_text_failed", { p_id: id, p_error: outcome.error.slice(0, 300) });
      result.failed += 1;
      result.errors.push(`${client?.name ?? phone}: ${outcome.error}`);
    }
  }
  return result;
}

/**
 * Sending a text whose row already exists.
 *
 * `sendClientSms` writes the row and then sends it. A retry has the row
 * already — the same row, because two rows would be two texts on the client's
 * record for one thing somebody said once (0280) — so this is the second half
 * of that function and nothing else.
 *
 * The gate runs again on the way out, as it does for a scheduled text: a
 * client who withdrew consent since the first attempt is not texted on the
 * retry.
 */
export async function resendRecorded(
  supabase: SupabaseClient<Database>,
  id: string,
  params: {
    phone: string;
    body: string;
    clientName: string;
    clientId: string;
    ghlId: string | null;
  },
): Promise<SendResult> {
  const fail = async (error: string): Promise<SendResult> => {
    await supabase.rpc("record_text_failed", { p_id: id, p_error: error.slice(0, 300) });
    return { ok: false, error, recorded: true };
  };

  // The gate, again. Consent can have gone since the first attempt.
  const { data: consent } = await supabase
    .from("client_sms_consent")
    .select("can_text")
    .eq("client_id", params.clientId)
    .maybeSingle();
  if (!consent?.can_text) {
    return fail("Consent for that number has gone since, so it was not sent again.");
  }

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
    await supabase.from("clients").update({ ghl_id: contactId }).eq("id", params.clientId);
  }

  const sent = await ghlSend({ contactId, message: params.body });
  if (!sent.ok) return fail(sent.error);

  const { error: recordError } = await supabase.rpc("record_text_sent", {
    p_id: id,
    p_provider_id: sent.data || null,
  });
  if (recordError) {
    return {
      ok: false,
      error: `The text went, but the record of it did not save. ${recordError.message}`,
      recorded: true,
    };
  }

  return { ok: true, id };
}

/**
 * Asking the provider what became of the texts it took.
 *
 * The practice only ever learned that GoHighLevel accepted a message.
 * Accepting is not delivering, so a text the carrier dropped an hour later
 * went on reading as sent, and 'Delivered' was unknowable (0287).
 *
 * Asked rather than waited for. The webhook exists too, but it needs
 * GoHighLevel to offer a trigger for outbound message status, which is theirs
 * to offer; this needs nothing but the receipt the practice already holds.
 *
 * A day's worth, and only the ones still unsettled: a delivered text is
 * finished and a failed one is somebody's to act on.
 */
export async function catchUpOnTextStatuses(
  supabase: SupabaseClient<Database>,
  limit = 40,
): Promise<{ asked: number; changed: number; errors: string[] }> {
  const result = { asked: 0, changed: 0, errors: [] as string[] };

  const { data: waiting, error } = await supabase
    .from("sms_messages")
    .select("id, provider_message_id, status")
    .eq("direction", "Outgoing")
    .in("status", ["Sent", "Sending", "Queued"])
    .not("provider_message_id", "is", null)
    .gte("created_at", new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
    .order("created_at", { ascending: false })
    .limit(limit);

  if (error) {
    result.errors.push(error.message);
    return result;
  }

  for (const row of waiting ?? []) {
    if (!row.provider_message_id) continue;
    result.asked += 1;
    const said = await messageStatus(row.provider_message_id);
    if (!said.ok) {
      result.errors.push(said.error);
      continue;
    }
    const { data } = await supabase.rpc("record_text_status", {
      p_provider_id: row.provider_message_id,
      p_status: said.data.status,
      p_error: said.data.error,
      p_payload: null,
    });
    const answer = Array.isArray(data) ? data[0] : data;
    if (answer?.matched && answer.status !== row.status) result.changed += 1;
  }

  return result;
}
