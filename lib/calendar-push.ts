import "server-only";
import type { SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@/lib/database.types";
import { ensureFreshToken, createEvent, updateEvent, deleteEvent } from "@/lib/graph";
import type { TokenAccess } from "@/lib/sync";

/**
 * Sends the calendar rows the database has queued.
 *
 * The reminder trigger writes a calendar_events row and marks it Pending, or
 * marks an existing one To remove. It cannot talk to Microsoft itself and
 * should not: a database that makes outbound calls to a third party is a
 * database that hangs when that third party is slow.
 *
 * So this is the other half. It runs straight after the action that set the
 * date — so the appointment is usually in Outlook before the page reloads —
 * and again on the nightly sweep, which is what catches the ones that failed
 * because somebody's laptop was shut or Microsoft was having a morning.
 *
 * Failure is never fatal here. The row already exists in the CRM; not
 * reaching Outlook is worth recording and worth retrying, and worth nobody's
 * save being rejected over.
 */
export async function pushPendingEvents(
  supabase: SupabaseClient<Database>,
  staffId: string,
  tokens: TokenAccess,
): Promise<{ pushed: number; removed: number; failed: number }> {
  const result = { pushed: 0, removed: 0, failed: 0 };

  const { data: queued } = await supabase
    .from("calendar_events")
    .select("id, title, starts_at, ends_at, location, note, push_state, outlook_event_id, client_id")
    .eq("staff_id", staffId)
    .in("push_state", ["Pending", "To remove"])
    .limit(50);

  if (!queued || queued.length === 0) return result;

  const bundle = await tokens.read();
  if (!bundle) {
    // No connection is not a failure to record against each event — it is one
    // fact about the person, and saying it fifty times helps nobody.
    await supabase
      .from("calendar_events")
      .update({ push_state: "Not pushed", push_error: "No Outlook account is connected." })
      .eq("staff_id", staffId)
      .eq("push_state", "Pending");
    return result;
  }

  let token: string;
  try {
    token = await ensureFreshToken(bundle, tokens.write);
  } catch (err) {
    const message = err instanceof Error ? err.message : "The connection could not be refreshed.";
    await supabase
      .from("calendar_events")
      .update({ push_state: "Failed", push_error: message.slice(0, 300) })
      .eq("staff_id", staffId)
      .eq("push_state", "Pending");
    return result;
  }

  // Client numbers, so a pushed event carries the tag that lets the pull
  // recognise it later.
  const clientIds = [...new Set(queued.map((e) => e.client_id).filter(Boolean))] as string[];
  const { data: clients } = await supabase
    .from("clients")
    .select("id, client_no")
    .in("id", clientIds.length > 0 ? clientIds : ["00000000-0000-0000-0000-000000000000"]);
  const clientNo = new Map((clients ?? []).map((c) => [c.id, c.client_no]));

  for (const event of queued) {
    try {
      if (event.push_state === "To remove") {
        if (event.outlook_event_id) await deleteEvent(token, event.outlook_event_id);
        // The row goes with it. A reminder whose date was cleared is not a
        // record of anything — nothing happened.
        await supabase.from("calendar_events").delete().eq("id", event.id);
        result.removed += 1;
        continue;
      }

      const payload = {
        title: event.title,
        startsAt: new Date(event.starts_at),
        endsAt: new Date(event.ends_at),
        location: event.location ?? "",
        note: event.note ?? "",
        clientNo: event.client_id ? (clientNo.get(event.client_id) ?? null) : null,
      };

      if (event.outlook_event_id) {
        await updateEvent(token, event.outlook_event_id, payload);
        await supabase
          .from("calendar_events")
          .update({ push_state: "Pushed", push_error: "" })
          .eq("id", event.id);
      } else {
        const created = await createEvent(token, payload);
        await supabase
          .from("calendar_events")
          .update({
            outlook_event_id: created.id,
            outlook_web_link: created.webLink,
            push_state: "Pushed",
            push_error: "",
          })
          .eq("id", event.id);
      }
      result.pushed += 1;
    } catch (err) {
      const message = err instanceof Error ? err.message : "unknown error";
      await supabase
        .from("calendar_events")
        .update({ push_state: "Failed", push_error: message.slice(0, 300) })
        .eq("id", event.id);
      result.failed += 1;
    }
  }

  return result;
}
