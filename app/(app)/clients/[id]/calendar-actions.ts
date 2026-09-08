"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { ownAccess } from "@/lib/sync-callers";
import { ensureFreshToken, createEvent, deleteEvent } from "@/lib/graph";

export type EventState = { error: string | null; ok: string | null };

const KINDS = ["Coaching visit", "Intake appointment", "Counselor call", "Other"] as const;

/**
 * Creates an appointment and puts it in the staff member's Outlook calendar.
 *
 * The row is written first and the push happens after. If Outlook is
 * unreachable the appointment still exists here, marked as not pushed, rather
 * than being lost because a third party was having a bad morning — and the
 * next sync or a manual retry can carry it over.
 */
export async function createClientEvent(
  _prev: EventState,
  formData: FormData,
): Promise<EventState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const clientId = String(formData.get("client_id") ?? "");
  const kind = String(formData.get("kind") ?? "Coaching visit");
  const title = String(formData.get("title") ?? "").trim();
  const startsAt = String(formData.get("starts_at") ?? "");
  const minutes = Number(formData.get("minutes") ?? 60);

  if (!clientId) return { error: "No client given.", ok: null };
  if (!KINDS.includes(kind as (typeof KINDS)[number])) {
    return { error: "Unknown kind of appointment.", ok: null };
  }
  if (!title) return { error: "Give the appointment a title.", ok: null };
  if (!startsAt) return { error: "Say when it starts.", ok: null };
  if (!(minutes > 0)) return { error: "An appointment lasts more than no time.", ok: null };

  const start = new Date(startsAt);
  if (Number.isNaN(start.getTime())) return { error: "Check the start time.", ok: null };
  const end = new Date(start.getTime() + minutes * 60000);

  const supabase = await createClient();

  const { data: client } = await supabase
    .from("clients")
    .select("client_no, name")
    .eq("id", clientId)
    .maybeSingle();

  if (!client) return { error: "That client is not there.", ok: null };

  const { data: row, error } = await supabase
    .from("calendar_events")
    .insert({
      client_id: clientId,
      staff_id: me.id,
      kind,
      title,
      starts_at: start.toISOString(),
      ends_at: end.toISOString(),
      location: String(formData.get("location") ?? "").trim(),
      note: String(formData.get("note") ?? "").trim(),
      origin: "CRM",
      push_state: "Pending",
      created_by: me.id,
    })
    .select("id")
    .single();

  if (error) return { error: error.message, ok: null };

  // ── into Outlook ───────────────────────────────────────────
  const { tokens } = ownAccess(supabase, me.id);
  const bundle = await tokens.read();

  if (!bundle) {
    await supabase
      .from("calendar_events")
      .update({ push_state: "Not pushed", push_error: "No Outlook account is connected." })
      .eq("id", row.id);
    revalidatePath(`/clients/${clientId}`);
    return {
      error: null,
      ok: "Appointment saved. It is not in Outlook — connect your account on the dashboard and it will go over on the next sync.",
    };
  }

  try {
    const token = await ensureFreshToken(bundle, tokens.write);
    const created = await createEvent(token, {
      title,
      startsAt: start,
      endsAt: end,
      location: String(formData.get("location") ?? "").trim(),
      note: String(formData.get("note") ?? "").trim(),
      clientNo: client.client_no === null ? null : Number(client.client_no),
    });

    await supabase
      .from("calendar_events")
      .update({
        outlook_event_id: created.id,
        outlook_web_link: created.webLink,
        push_state: "Pushed",
        push_error: "",
      })
      .eq("id", row.id);

    revalidatePath(`/clients/${clientId}`);
    return { error: null, ok: `Appointment saved and added to your Outlook calendar.` };
  } catch (err) {
    const message = err instanceof Error ? err.message : "unknown error";
    await supabase
      .from("calendar_events")
      .update({ push_state: "Failed", push_error: message.slice(0, 300) })
      .eq("id", row.id);

    revalidatePath(`/clients/${clientId}`);
    return {
      error: null,
      ok: `Appointment saved, but Outlook refused it: ${message}. It is recorded here either way.`,
    };
  }
}

/**
 * Removes an appointment, and its Outlook copy if this system put one there.
 *
 * An appointment that came from Outlook is only unlinked here — deleting
 * somebody's own calendar entry because they untagged it in the CRM would be
 * reaching further than asked.
 */
export async function deleteClientEvent(
  _prev: EventState,
  formData: FormData,
): Promise<EventState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const id = String(formData.get("event_id") ?? "");
  const supabase = await createClient();

  const { data: event } = await supabase
    .from("calendar_events")
    .select("id, client_id, staff_id, origin, outlook_event_id")
    .eq("id", id)
    .maybeSingle();

  if (!event) return { error: "That appointment is no longer there.", ok: null };

  if (event.origin === "CRM" && event.outlook_event_id && event.staff_id === me.id) {
    try {
      const { tokens } = ownAccess(supabase, me.id);
      const bundle = await tokens.read();
      if (bundle) {
        const token = await ensureFreshToken(bundle, tokens.write);
        await deleteEvent(token, event.outlook_event_id);
      }
    } catch {
      // The row still goes. A calendar entry left behind in Outlook is a
      // nuisance; a CRM that will not let go of a cancelled appointment is
      // worse, and the person can delete it there.
    }
  }

  const { error } = await supabase.from("calendar_events").delete().eq("id", id);
  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${event.client_id}`);
  return { error: null, ok: "Appointment removed." };
}

/** Records that the offer to log hours has been answered, either way. */
export async function answerHoursPrompt(
  _prev: EventState,
  formData: FormData,
): Promise<EventState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const supabase = await createClient();
  const { error } = await supabase
    .from("calendar_events")
    .update({ hours_prompt_answered_at: new Date().toISOString() })
    .eq("id", String(formData.get("event_id") ?? ""));

  if (error) return { error: error.message, ok: null };

  revalidatePath(`/clients/${String(formData.get("client_id") ?? "")}`);
  return { error: null, ok: "Noted." };
}
