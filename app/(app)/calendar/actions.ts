"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { ownAccess } from "@/lib/sync-callers";
import { ensureFreshToken, clientTag } from "@/lib/graph";
import { pushPendingEvents } from "@/lib/calendar-push";
import { patchOutlookEvent } from "@/lib/calendar-view";
import { practiceWallToDate } from "@/lib/practice-time";

export type CalendarState = { error: string | null; ok: string | null };

const KINDS = ["Coaching visit", "Intake appointment", "Counselor call", "Other"];

/**
 * Creates or edits an appointment from the Calendar screen (Messaging brief, M).
 *
 * New, or made in the CRM: a calendar_events row, pushed to Outlook the way
 * appointments always have been (lib/calendar-push). Made in Outlook: its
 * title, time and place are changed in Outlook itself, and choosing a client
 * puts the client's tag in the title so the sync recognises it. Nothing here
 * logs hours - a finished visit only offers to.
 */
export async function saveCalendarEvent(_prev: CalendarState, formData: FormData): Promise<CalendarState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const str = (k: string) => String(formData.get(k) ?? "").trim();
  const crmId = str("crm_id");
  const outlookId = str("outlook_id");
  const clientId = str("client_id") || null;
  const kind = KINDS.includes(str("kind")) ? str("kind") : "Other";
  const title = str("title");
  const minutes = Number(str("minutes") || 60);
  const start = practiceWallToDate(str("starts_at"));

  if (!title) return { error: "Give it a title.", ok: null };
  if (!start) return { error: "Say when it starts.", ok: null };
  if (!(minutes > 0 && minutes <= 24 * 60)) return { error: "Say how long it lasts, in minutes.", ok: null };
  const end = new Date(start.getTime() + minutes * 60000);

  const supabase = await createClient();
  const { tokens } = ownAccess(supabase, me.id);

  let clientNo: number | null = null;
  if (clientId) {
    const { data: client } = await supabase.from("clients").select("client_no").eq("id", clientId).maybeSingle();
    if (!client) return { error: "That client is not there.", ok: null };
    clientNo = client.client_no === null ? null : Number(client.client_no);
  }

  const fields = {
    client_id: clientId,
    kind,
    title,
    starts_at: start.toISOString(),
    ends_at: end.toISOString(),
    location: str("location"),
  };

  // ── an event that came from Outlook ─────────────────────────
  if (!crmId && outlookId) {
    const bundle = await tokens.read();
    if (!bundle) return { error: "Your Outlook is not connected.", ok: null };
    try {
      const token = await ensureFreshToken(bundle, tokens.write);
      const tag = clientNo === null ? "" : clientTag(clientNo);
      await patchOutlookEvent(token, outlookId, {
        subject: tag && !title.includes(tag) ? `${title} ${tag}` : title,
        startsAt: start,
        endsAt: end,
        location: fields.location,
      });
    } catch (err) {
      return { error: err instanceof Error ? err.message : "Outlook refused the change.", ok: null };
    }
    revalidatePath("/calendar");
    return { error: null, ok: clientNo === null ? "Changed in Outlook." : "Changed in Outlook, and tagged with the client." };
  }

  // ── one of ours: the row, then Outlook ──────────────────────
  if (crmId) {
    const { data: row } = await supabase
      .from("calendar_events")
      .select("id, origin, outlook_event_id")
      .eq("id", crmId)
      .eq("staff_id", me.id)
      .maybeSingle();
    if (!row) return { error: "That appointment is not yours to change.", ok: null };

    if (row.origin === "Outlook" && row.outlook_event_id) {
      // Pulled in from Outlook: change it there, never overwriting its body.
      const bundle = await tokens.read();
      if (!bundle) return { error: "Your Outlook is not connected.", ok: null };
      try {
        const token = await ensureFreshToken(bundle, tokens.write);
        const tag = clientNo === null ? "" : clientTag(clientNo);
        await patchOutlookEvent(token, row.outlook_event_id, {
          subject: tag && !title.includes(tag) ? `${title} ${tag}` : title,
          startsAt: start,
          endsAt: end,
          location: fields.location,
        });
      } catch (err) {
        return { error: err instanceof Error ? err.message : "Outlook refused the change.", ok: null };
      }
      await supabase.from("calendar_events").update(fields).eq("id", row.id);
    } else {
      const { error } = await supabase
        .from("calendar_events")
        .update({ ...fields, note: str("note"), push_state: "Pending", push_error: "" })
        .eq("id", row.id);
      if (error) return { error: error.message, ok: null };
      await pushPendingEvents(supabase, me.id, tokens);
    }
    revalidatePath("/calendar");
    if (clientId) revalidatePath(`/clients/${clientId}`);
    return { error: null, ok: "Saved, and changed in Outlook." };
  }

  // ── new ─────────────────────────────────────────────────────
  const { error } = await supabase.from("calendar_events").insert({
    ...fields,
    staff_id: me.id,
    note: str("note"),
    origin: "CRM",
    push_state: "Pending",
    created_by: me.id,
  });
  if (error) return { error: error.message, ok: null };
  const pushed = await pushPendingEvents(supabase, me.id, tokens);

  revalidatePath("/calendar");
  if (clientId) revalidatePath(`/clients/${clientId}`);
  return {
    error: null,
    ok:
      pushed.failed > 0
        ? "Saved here; Outlook refused it this time - it will be tried again on the next sync."
        : pushed.pushed > 0
          ? "Saved and added to your Outlook calendar."
          : "Saved. It goes to Outlook once your account is connected.",
  };
}
