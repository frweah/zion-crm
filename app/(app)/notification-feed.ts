"use server";

import { revalidatePath } from "next/cache";
import { getCurrentStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { mailWaiting } from "./inbox-mail";

/**
 * Everything waiting for one person, in one list (Design language, §1).
 *
 * The bell is the one place somebody looks to find out what has happened:
 * a client texted, a colleague messaged, a task is due, an alert was raised
 * for their role. Those live in four different tables and used to be found on
 * four different screens.
 *
 * Nothing here is a new kind of record. It reads what the practice already
 * keeps and puts it in time order, so what the bell says and what the screens
 * say cannot drift - and the two things it offers, marking a conversation read
 * and putting an alert aside until tomorrow, are the same two actions the
 * dashboard already had.
 */
export type FeedItem = {
  key: string;
  kind: "Text" | "Chat" | "Website" | "Mail" | "Task" | "Alert";
  text: string;
  detail: string;
  at: string;
  href: string;
  /** A conversation can be marked read from here; an alert put aside. */
  read?: { conversationId: string; seq: number };
  snooze?: string;
  bad?: boolean;
};

export async function notificationFeed(): Promise<FeedItem[]> {
  const me = await getCurrentStaff();
  if (!me) return [];
  const supabase = await createClient();
  const day = today();

  const [{ data: outside }, { data: chat }, { data: tasks }, { data: alerts }, { data: snoozes }, mail] =
    await Promise.all([
      supabase.rpc("message_inbox", { p_show: "open" }),
      supabase.rpc("my_unread"),
      supabase
        .from("tasks")
        .select("id, title, due, client_id")
        .eq("assigned_staff_id", me.id)
        .eq("status", "Open")
        .lte("due", day)
        .order("due")
        .limit(20),
      supabase
        .from("notifications")
        .select("id, level, text, href, created_at, roles")
        .is("resolved_at", null)
        .order("created_at", { ascending: false })
        .limit(40),
      supabase.from("staff_alert_snoozes").select("notification_id").gte("until", day),
      // Mail is a separate world: if Outlook is not connected, or the token
      // has gone stale, the bell still shows everything else.
      mailWaiting(5).catch(() => null),
    ]);

  const items: FeedItem[] = [];
  const isId = (v: string | null | undefined): v is string => typeof v === "string" && v.length > 0;

  // A conversation needs answering when it is unread and it is this person's
  // - theirs, or nobody's.
  for (const r of outside ?? []) {
    if ((r.unread ?? 0) <= 0 || !isId(r.conversation_id)) continue;
    if (!(me.role === "Admin" || !r.assigned_staff_id || r.assigned_staff_id === me.id)) continue;
    const web = r.kind === "web";
    items.push({
      key: `conv-${r.conversation_id}`,
      kind: web ? "Website" : "Text",
      text: r.client_name || r.who || (web ? "A visitor" : "Unknown number"),
      detail: "sent a message",
      at: r.last_message_at ?? new Date().toISOString(),
      href: web || !r.client_id
        ? `/messages/texts?tab=${web ? "web" : "texts"}&c=${r.conversation_id}`
        : `/clients/${r.client_id}?tab=messages`,
    });
  }

  const chatIds = (chat ?? [])
    .filter((r) => (r.unread ?? 0) > 0)
    .map((r) => r.conversation_id)
    .filter(isId);
  const { data: chatRows } = chatIds.length
    ? await supabase.from("conversations").select("id, title, last_message_at").in("id", chatIds)
    : { data: [] as { id: string; title: string; last_message_at: string | null }[] };
  const chatById = new Map((chatRows ?? []).map((c) => [c.id, c]));
  for (const r of chat ?? []) {
    if ((r.unread ?? 0) <= 0 || !isId(r.conversation_id)) continue;
    const c = chatById.get(r.conversation_id);
    items.push({
      key: `chat-${r.conversation_id}`,
      kind: "Chat",
      text: c?.title || "A colleague",
      detail: `${r.unread} unread`,
      at: c?.last_message_at ?? new Date().toISOString(),
      href: `/messages?c=${r.conversation_id}`,
    });
  }

  for (const m of mail?.oldest ?? []) {
    items.push({
      key: `mail-${m.id}`,
      kind: "Mail",
      text: m.from || "(no sender)",
      detail: m.subject,
      at: m.receivedAt,
      href: `/mail?id=${encodeURIComponent(m.id)}`,
    });
  }

  for (const t of tasks ?? []) {
    items.push({
      key: `task-${t.id}`,
      kind: "Task",
      text: t.title,
      detail: t.due && t.due < day ? `overdue since ${t.due}` : "due today",
      at: `${t.due ?? day}T08:00:00.000Z`,
      href: t.client_id ? `/clients/${t.client_id}` : "/tasks",
      bad: Boolean(t.due && t.due < day),
    });
  }

  const asleep = new Set((snoozes ?? []).map((s: { notification_id: string }) => s.notification_id));
  for (const a of alerts ?? []) {
    if (asleep.has(a.id)) continue;
    if (!(a.roles ?? []).includes(me.role)) continue;
    items.push({
      key: `alert-${a.id}`,
      kind: "Alert",
      text: a.text,
      detail: a.level === "bad" ? "needs attention" : "worth a look",
      at: a.created_at,
      href: a.href ?? "/dashboard",
      snooze: a.id,
      bad: a.level === "bad",
    });
  }

  return items.sort((x, y) => y.at.localeCompare(x.at)).slice(0, 40);
}

/** Put an alert aside until tomorrow, from the bell. */
export async function dismissFromBell(formData: FormData): Promise<void> {
  const me = await getCurrentStaff();
  if (!me) return;
  const id = String(formData.get("notification_id") ?? "");
  if (!/^[0-9a-f-]{36}$/.test(id)) return;
  const tomorrow = new Date(Date.parse(`${today()}T12:00:00Z`) + 86400000).toISOString().slice(0, 10);
  const supabase = await createClient();
  await supabase
    .from("staff_alert_snoozes")
    .upsert({ staff_id: me.id, notification_id: id, until: tomorrow }, { onConflict: "staff_id,notification_id" });
  revalidatePath("/dashboard");
}
