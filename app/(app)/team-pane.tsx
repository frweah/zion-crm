"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { sendChatMessage, markRead, type ChatState } from "./messages/actions";
import { useActionState } from "react";

/**
 * Team chat, over whatever page is open (owner, 30 Oct 2026).
 *
 * The page underneath stays exactly where it was - the same scroll, the same
 * half-filled form, the same unsaved authorization - because answering a
 * colleague should not cost somebody the thing they were doing. That is the
 * whole reason this is a pane and not a route: a navigation would unmount it.
 *
 * Which is also why it reads and writes directly rather than going through the
 * page's data. Nothing on the screen behind it is re-rendered when a message
 * arrives.
 *
 * The full page at /team is the same conversations for a long read. This is
 * for the sentence somebody needs now.
 */

const initial: ChatState = { error: null, ok: null };

type Thread = {
  id: string;
  title: string;
  last_message_at: string | null;
  last_seq: number;
  unread: number;
  line: string;
  who: string;
};

type Line = {
  id: string;
  seq: number;
  sender_label: string;
  sender_staff_id: string | null;
  body: string;
  created_at: string;
  edited_at: string | null;
  removed_at: string | null;
};

/** "2:30 pm" for today, "4 Nov" for anything older. */
function when(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const today = new Date();
  const sameDay =
    d.getFullYear() === today.getFullYear() &&
    d.getMonth() === today.getMonth() &&
    d.getDate() === today.getDate();
  return sameDay
    ? d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
    : d.toLocaleDateString(undefined, { day: "numeric", month: "short" });
}

export function TeamPane({ myId }: { myId: string }) {
  const [open, setOpen] = useState(false);
  const [threads, setThreads] = useState<Thread[]>([]);
  const [current, setCurrent] = useState<string | null>(null);
  const [lines, setLines] = useState<Line[]>([]);
  const [state, send, sending] = useActionState(sendChatMessage, initial);
  const bottom = useRef<HTMLDivElement | null>(null);
  const form = useRef<HTMLFormElement | null>(null);

  // ── the list ───────────────────────────────────────────────
  const loadThreads = useCallback(async () => {
    const supabase = createClient();
    const [{ data: convs }, { data: unread }] = await Promise.all([
      supabase
        .from("conversations")
        .select("id, title, last_message_at, last_seq")
        .eq("kind", "internal")
        .is("archived_at", null)
        .order("last_message_at", { ascending: false, nullsFirst: false })
        .limit(50),
      supabase.rpc("my_unread"),
    ]);

    const counts = new Map(
      ((unread ?? []) as { conversation_id: string; unread: number }[]).map((r) => [
        r.conversation_id,
        r.unread ?? 0,
      ]),
    );
    const rows = (convs ?? []) as { id: string; title: string | null; last_message_at: string | null; last_seq: number }[];

    // The last line of each, which is what makes a list of threads readable.
    // One query for all of them rather than one each.
    const { data: last } = await supabase
      .from("messages")
      .select("conversation_id, seq, body, sender_label, removed_at")
      .in("conversation_id", rows.map((r) => r.id))
      .order("seq", { ascending: false })
      .limit(200);

    const latest = new Map<string, { body: string; who: string; removed: boolean }>();
    for (const m of (last ?? []) as { conversation_id: string; body: string; sender_label: string; removed_at: string | null }[]) {
      if (!latest.has(m.conversation_id)) {
        latest.set(m.conversation_id, {
          body: m.body,
          who: m.sender_label,
          removed: m.removed_at !== null,
        });
      }
    }

    setThreads(
      rows.map((r) => {
        const l = latest.get(r.id);
        return {
          id: r.id,
          title: r.title?.trim() || "A conversation",
          last_message_at: r.last_message_at,
          last_seq: r.last_seq,
          unread: counts.get(r.id) ?? 0,
          who: l?.who ?? "",
          line: l?.removed ? "Taken back" : (l?.body ?? "").split("\n")[0].slice(0, 80),
        };
      }),
    );
  }, []);

  // ── one thread ─────────────────────────────────────────────
  const loadLines = useCallback(async (id: string) => {
    const supabase = createClient();
    const { data } = await supabase
      .from("messages")
      .select("id, seq, sender_label, sender_staff_id, body, created_at, edited_at, removed_at")
      .eq("conversation_id", id)
      .order("seq", { ascending: true })
      .limit(200);
    const rows = (data ?? []) as Line[];
    setLines(rows);
    // Opening a thread is reading it, which is what the other person's receipt
    // is waiting for.
    const top = rows.at(-1)?.seq;
    if (top) await markRead(id, top);
    void loadThreads();
  }, [loadThreads]);

  useEffect(() => {
    if (!open) return;
    void loadThreads();
  }, [open, loadThreads]);

  useEffect(() => {
    if (!open || !current) return;
    void loadLines(current);
  }, [open, current, loadLines]);

  // A message arriving anywhere refreshes the list, and the open thread if it
  // is the one. live-messaging.tsx already hears every insert over Realtime
  // and says so on the window, so this adds no second subscription.
  useEffect(() => {
    const onMessage = (e: Event) => {
      const row = (e as CustomEvent).detail as { conversation_id?: string } | undefined;
      if (!open) return;
      void loadThreads();
      if (current && row?.conversation_id === current) void loadLines(current);
    };
    window.addEventListener("zion:message", onMessage);
    return () => window.removeEventListener("zion:message", onMessage);
  }, [open, current, loadThreads, loadLines]);

  // Opened from the pop-up, on whatever page somebody is looking at.
  useEffect(() => {
    const onOpen = (e: Event) => {
      const id = (e as CustomEvent).detail as string | undefined;
      setOpen(true);
      if (id) setCurrent(id);
    };
    window.addEventListener("zion:open-team", onOpen);
    return () => window.removeEventListener("zion:open-team", onOpen);
  }, []);

  // Escape closes it, because a pane over somebody's work has to be easy to
  // get out of.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  useEffect(() => {
    bottom.current?.scrollIntoView({ block: "end" });
  }, [lines]);

  // Sent: clear the box and show it, without reloading the page behind.
  useEffect(() => {
    if (state.ok === "sent") {
      form.current?.reset();
      if (current) void loadLines(current);
    }
  }, [state, current, loadLines]);

  if (!open) return null;

  const thread = threads.find((t) => t.id === current) ?? null;

  return (
    <>
      {/* The page underneath is still there and still scrolled where it was;
          this only stops a click reaching it by accident. */}
      <div className="pane-shade" onClick={() => setOpen(false)} aria-hidden="true" />
      <aside className="team-pane" aria-label="Team">
        <div className="row2" style={{ justifyContent: "space-between", alignItems: "center" }}>
          <b>{thread ? thread.title : "Team"}</b>
          <div className="row2" style={{ gap: 6 }}>
            {thread && (
              <button className="btn ghost" type="button" onClick={() => setCurrent(null)}>
                All threads
              </button>
            )}
            <Link className="btn ghost" href={current ? `/team?c=${current}` : "/team"}>
              Full page
            </Link>
            <button className="btn ghost" type="button" onClick={() => setOpen(false)}>
              Close
            </button>
          </div>
        </div>

        {!thread && (
          <div className="pane-list">
            {threads.length === 0 ? (
              <div className="empty">Nothing yet — start one from the full page.</div>
            ) : (
              threads.map((t) => (
                <button key={t.id} type="button" className="pane-row" onClick={() => setCurrent(t.id)}>
                  <span className="row2" style={{ justifyContent: "space-between" }}>
                    <b>{t.title}</b>
                    <span className="lock">{when(t.last_message_at)}</span>
                  </span>
                  <span className="lock">
                    {t.who && `${t.who}: `}
                    {t.line}
                  </span>
                  {t.unread > 0 && <span className="nav-badge">{t.unread}</span>}
                </button>
              ))
            )}
          </div>
        )}

        {thread && (
          <>
            <div className="pane-lines">
              {lines.map((l) => (
                <div key={l.id} className={"pane-line" + (l.sender_staff_id === myId ? " mine" : "")}>
                  <span className="lock">
                    {l.sender_label || "A colleague"} · {when(l.created_at)}
                    {l.edited_at && " · edited"}
                  </span>
                  <span>{l.removed_at ? <i>Taken back</i> : l.body}</span>
                </div>
              ))}
              <div ref={bottom} />
            </div>

            {state.error && <div className="alert bad">{state.error}</div>}

            <form action={send} ref={form}>
              <input type="hidden" name="conversation_id" value={thread.id} />
              <input type="hidden" name="attachments" value="[]" />
              <label className="field" htmlFor="pane-body">
                Say it
                <textarea id="pane-body" name="body" rows={2} required />
              </label>
              <button className="btn" type="submit" disabled={sending}>
                {sending ? "Sending…" : "Say it"}
              </button>
            </form>
          </>
        )}
      </aside>
    </>
  );
}
