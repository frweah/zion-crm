"use server";

import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";
import { ownAccess } from "@/lib/sync-callers";
import { ensureFreshToken } from "@/lib/graph";
import { ONLINE_MEETING_SCOPE, hasScope } from "@/lib/microsoft";

export type MeetingState = { error: string | null; ok: string | null; join?: string };

/**
 * "Start a Teams meeting", on a thread or on a client's record.
 *
 * Through this person's own Graph connection, so the meeting is theirs and
 * the link is one they are the organiser of. The CRM keeps the join link and
 * nothing else: the meeting happens in Teams, and no recording, transcript or
 * attendance ever comes back here.
 *
 * Until the owner has granted `OnlineMeetings.ReadWrite` in Azure and this
 * person has consented to it on their connection, the answer is that it is not
 * connected yet. Said rather than attempted, because a Microsoft consent error
 * page is not something a person reading a CRM can act on.
 */
export async function startTeamsMeeting(
  _prev: MeetingState,
  formData: FormData,
): Promise<MeetingState> {
  const me = await getCurrentStaff();
  if (!me) return { error: "You are not signed in.", ok: null };

  const conversation = String(formData.get("conversation_id") ?? "");
  const clientId = String(formData.get("client_id") ?? "");
  const subject = String(formData.get("subject") ?? "").trim() || "Zion Voc Rehab";

  const supabase = await createClient();
  const { tokens } = ownAccess(supabase, me.id);
  const bundle = await tokens.read();

  if (!bundle) {
    return { error: "Connect Microsoft 365 first, under your name.", ok: null };
  }
  // The scope is on the connection or it is not. Asking Graph and reading the
  // refusal would mean showing somebody a consent error.
  //
  // hasScope rather than a plain includes: Microsoft hands a granted scope
  // back as a bare name or as the full graph URL, and the URL form would have
  // made this say "not connected yet" about a connection that has it.
  if (!hasScope(bundle.scopes ?? "", ONLINE_MEETING_SCOPE)) {
    return {
      error: "Not connected yet — Teams meetings need one more Microsoft permission.",
      ok: null,
    };
  }

  const token = await ensureFreshToken(bundle, tokens.write);
  const start = new Date();
  const end = new Date(start.getTime() + 30 * 60 * 1000);

  const response = await fetch("https://graph.microsoft.com/v1.0/me/onlineMeetings", {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      startDateTime: start.toISOString(),
      endDateTime: end.toISOString(),
      subject,
    }),
  });

  if (!response.ok) {
    // Microsoft's own wording, which is at least specific, rather than a
    // sentence of ours guessing which of its reasons it was.
    const detail = await response.text();
    return { error: `Teams would not start the meeting: ${detail.slice(0, 200)}`, ok: null };
  }

  const meeting = (await response.json()) as { joinWebUrl?: string };
  const join = meeting.joinWebUrl;
  if (!join) return { error: "Teams started a meeting with no link to it.", ok: null };

  // The link goes in the thread, so whoever is in it can join.
  if (conversation) {
    await supabase.rpc("post_message", {
      p_conversation: conversation,
      p_body: `Teams meeting: ${join}`,
      p_attachments: [] as never,
      p_mentions: [],
      p_clients: clientId ? [clientId] : [],
    });
  }

  // And a line on the client's record, with the link. Not a note about what
  // was discussed: nobody has discussed anything yet.
  if (clientId) {
    await supabase.from("notes").insert({
      client_id: clientId,
      staff_id: me.id,
      staff_name: me.name,
      text: `Teams meeting started — ${join}`,
      type: "Meeting",
      category: "General progress",
    });
    revalidatePath(`/clients/${clientId}`);
  }

  revalidatePath("/team");
  return { error: null, ok: "Started.", join };
}
