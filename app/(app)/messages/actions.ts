"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import { getCurrentStaff } from "@/lib/session";

/**
 * Staff conversations (Messaging brief, foundation and B). Every write is one
 * of the database's own functions (0104, 0106), which decide who may: who is
 * in a conversation, whose message it is, and whether a document may be
 * attached where everybody in the room can open it.
 */
export type ChatState = { error: string | null; ok: string | null };

/** What the composer sends: a reference to a document already on a record. */
export type ChatAttachment = { kind: "client_file" | "form"; id: string; name: string };

export async function startDirect(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("start_direct_conversation", {
    p_other: String(formData.get("staff_id") ?? ""),
  });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error?.message ?? "It could not be started.")}`);
  redirect(`/messages?c=${data}`);
}

export async function startGroup(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc("start_group_conversation", {
    p_title: String(formData.get("title") ?? ""),
    p_staff: formData.getAll("staff_id").map(String),
    p_client: null,
  });
  if (error || !data) redirect(`/messages?error=${encodeURIComponent(error?.message ?? "It could not be started.")}`);
  redirect(`/messages?c=${data}`);
}

/**
 * A thread about a client, started from the client's record. It lands on that
 * client's Activity, where the rest of what has happened to them is.
 */
export async function startClientThread(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const clientId = String(formData.get("client_id") ?? "");
  const { data, error } = await supabase.rpc("start_group_conversation", {
    p_title: String(formData.get("title") ?? ""),
    p_staff: formData.getAll("staff_id").map(String),
    p_client: clientId,
  });
  if (error || !data) {
    redirect(`/clients/${clientId}?tab=activity&error=${encodeURIComponent(error?.message ?? "It could not be started.")}`);
  }
  redirect(`/messages?c=${data}`);
}

export async function addParticipant(_prev: ChatState, formData: FormData): Promise<ChatState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("add_conversation_participant", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
    p_staff: String(formData.get("staff_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages");
  return { error: null, ok: "They are in." };
}

export async function leaveConversation(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("leave_conversation", {
    p_conversation: String(formData.get("conversation_id") ?? ""),
  });
  if (error) redirect(`/messages?error=${encodeURIComponent(error.message)}`);
  redirect("/messages");
}

export async function archiveConversation(formData: FormData): Promise<void> {
  const supabase = await createClient();
  const id = String(formData.get("conversation_id") ?? "");
  const on = formData.get("archived") !== "no";
  const { error } = await supabase.rpc("archive_conversation", { p_conversation: id, p_archived: on });
  if (error) redirect(`/messages?error=${encodeURIComponent(error.message)}`);
  revalidatePath("/messages");
  redirect(on ? "/messages?archived=1" : `/messages?c=${id}`);
}

export async function sendChatMessage(_prev: ChatState, formData: FormData): Promise<ChatState> {
  const supabase = await createClient();
  const conversation = String(formData.get("conversation_id") ?? "");
  // The composer sends what it offered, as references; the database checks
  // each one against everybody in the conversation before it goes.
  let attachments: ChatAttachment[] = [];
  try {
    attachments = JSON.parse(String(formData.get("attachments") ?? "[]")) as ChatAttachment[];
  } catch {
    return { error: "Those attachments could not be read. Try choosing them again.", ok: null };
  }
  const { error } = await supabase.rpc("post_message", {
    p_conversation: conversation,
    p_body: String(formData.get("body") ?? ""),
    p_attachments: attachments as never,
    p_mentions: formData.getAll("mention").map(String),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages");
  return { error: null, ok: "sent" };
}

export async function editMessage(_prev: ChatState, formData: FormData): Promise<ChatState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("edit_message", {
    p_message: String(formData.get("message_id") ?? ""),
    p_body: String(formData.get("body") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages");
  return { error: null, ok: "saved" };
}

export async function removeMessage(_prev: ChatState, formData: FormData): Promise<ChatState> {
  const supabase = await createClient();
  const { error } = await supabase.rpc("remove_message", {
    p_message: String(formData.get("message_id") ?? ""),
  });
  if (error) return { error: error.message, ok: null };
  revalidatePath("/messages");
  return { error: null, ok: "removed" };
}

export async function markRead(conversationId: string, seq: number): Promise<void> {
  const supabase = await createClient();
  await supabase.rpc("mark_read", { p_conversation: conversationId, p_seq: seq });
}

/**
 * Opening a document attached to a message. The chat holds a reference, so the
 * file is fetched from where it has always been, and the storage rules - not
 * the chat - decide whether this person gets the link.
 */
export async function openChatAttachment(_prev: ChatState & { url?: string }, formData: FormData): Promise<ChatState & { url?: string }> {
  const supabase = await createClient();
  const { data: row } = await supabase
    .from("attachments")
    .select("storage_path")
    .eq("id", String(formData.get("attachment_id") ?? ""))
    .maybeSingle();
  if (!row) return { error: "That document is no longer one you can open.", ok: null };
  const { data, error } = await supabase.storage.from("client-files").createSignedUrl(row.storage_path, 120);
  if (error || !data?.signedUrl) return { error: "That document is not available to you.", ok: null };
  return { error: null, ok: null, url: data.signedUrl };
}

/** The unread-message email: counts and names after thirty minutes away, never the text. */
export async function setDigest(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const supabase = await createClient();
  if (formData.get("on") === "yes") {
    await supabase
      .from("staff_prefs")
      .upsert({ staff_id: me.id, key: "messages:email_digest", value: true }, { onConflict: "staff_id,key" });
  } else {
    await supabase.from("staff_prefs").delete().eq("staff_id", me.id).eq("key", "messages:email_digest");
  }
  revalidatePath("/messages");
}
