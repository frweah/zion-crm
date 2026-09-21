"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { outsideUnread } from "./inbox-count-actions";
import { mailWaiting } from "./inbox-mail";

/**
 * The messaging foundation's live half (Messaging brief), running in every
 * CRM window:
 *
 *   Presence. About once a minute the window says the person is online - or
 *   away, when there has been no pointer, key or touch for five minutes. Only
 *   the time of the last input is kept, in this window, to tell which; what
 *   was typed or where is never looked at, and nothing about it leaves.
 *
 *   Unread. The count of unread staff messages, for the sidebar's badge,
 *   refreshed whenever a message arrives.
 *
 *   A toast when a message arrives from somebody else: who, and a link - not
 *   the text, which may be about a client and the screen may be seen.
 *
 * Live delivery is Supabase Realtime, which sends each new message only to
 * those the database lets read it (0104).
 */

// ── the unread count, shared with the sidebar ────────────────
// One Inbox badge (21 Sept 2026): staff chat, live; texts and website chats,
// and the person's own unread mail, asked for every two minutes and whenever
// a message arrives.
let unreadTotal = 0;
let outsideTotal = 0;
const listeners = new Set<() => void>();
function setUnread(n: number) {
  unreadTotal = n;
  listeners.forEach((l) => l());
}
function setOutside(n: number) {
  outsideTotal = n;
  listeners.forEach((l) => l());
}
export function useUnreadMessages(): number {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => unreadTotal + outsideTotal,
    () => 0,
  );
}
const OUTSIDE_MS = 2 * 60 * 1000;

const IDLE_MS = 5 * 60 * 1000;
const BEAT_MS = 60 * 1000;

type Toast = { id: string; who: string; conversationId: string };

export function LiveMessaging({ myId, initialUnread }: { myId: string; initialUnread: number }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const lastInput = useRef(Date.now());

  useEffect(() => {
    setUnread(initialUnread);
  }, [initialUnread]);

  useEffect(() => {
    const supabase = createClient();

    // ── presence ─────────────────────────────────────────────
    const touched = () => {
      lastInput.current = Date.now();
    };
    const events = ["pointerdown", "keydown", "touchstart", "wheel"] as const;
    events.forEach((e) => window.addEventListener(e, touched, { passive: true }));
    const beat = () => {
      const state = Date.now() - lastInput.current > IDLE_MS ? "away" : "online";
      void supabase.rpc("presence_heartbeat", { p_state: state }).then(({ error }) => {
        if (error) console.warn("Presence heartbeat refused:", error.message);
      });
    };
    beat();
    const timer = window.setInterval(beat, BEAT_MS);

    // ── unread and toasts ────────────────────────────────────
    const refreshUnread = async () => {
      const { data } = await supabase.rpc("my_unread");
      setUnread((data ?? []).reduce((s, r) => s + (r.unread ?? 0), 0));
    };
    const refreshOutside = async () => {
      try {
        const [outside, mail] = await Promise.all([outsideUnread(), mailWaiting(0)]);
        setOutside(outside + mail.count);
      } catch {
        // A badge that cannot be worked out keeps its last number.
      }
    };
    void refreshOutside();
    const outsideTimer = window.setInterval(() => void refreshOutside(), OUTSIDE_MS);
    const channel = supabase
      .channel("messages-live")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, (payload) => {
        const row = payload.new as { id: string; conversation_id: string; sender_staff_id: string | null; sender_label: string; sender_kind: string };
        if (row.sender_staff_id === myId) return;
        void refreshUnread();
        if (row.sender_kind !== "staff") void refreshOutside();
        window.dispatchEvent(new CustomEvent("zion:message", { detail: row }));
        if (window.location.pathname === "/messages" && window.location.search.includes(row.conversation_id)) return;
        const who = row.sender_kind === "staff" ? row.sender_label || "A colleague" : row.sender_kind === "client" ? "A client" : "A visitor";
        // The same message can arrive twice (a reconnect, a retry); one toast.
        setToasts((t) => (t.some((x) => x.id === row.id) ? t : [...t.slice(-2), { id: row.id, who, conversationId: row.conversation_id }]));
        window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== row.id)), 8000);
      })
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "read_receipts" }, () => {
        void refreshUnread();
        void refreshOutside();
      })
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "read_receipts" }, () => {
        void refreshUnread();
        void refreshOutside();
      })
      .subscribe();

    return () => {
      events.forEach((e) => window.removeEventListener(e, touched));
      window.clearInterval(timer);
      window.clearInterval(outsideTimer);
      void supabase.removeChannel(channel);
    };
  }, [myId]);

  return (
    <div className="toasts" aria-live="polite" aria-atomic="false">
      {toasts.map((t) => (
        <div key={t.id} className="toast" role="status">
          <span>
            New message from <b>{t.who}</b>
          </span>
          <Link href={`/messages?c=${t.conversationId}`} className="btn ghost" style={{ padding: "2px 10px" }}>
            Open
          </Link>
          <button
            type="button"
            className="btn ghost"
            aria-label="Dismiss"
            style={{ padding: "2px 8px" }}
            onClick={() => setToasts((all) => all.filter((x) => x.id !== t.id))}
          >
            ×
          </button>
        </div>
      ))}
    </div>
  );
}

/** A colleague's presence: a dot and the word, never the dot alone. */
export function PresenceLabel({ status }: { status: "online" | "away" | "offline" | string }) {
  const s = status === "online" || status === "away" ? status : "offline";
  return (
    <span className={`presence ${s}`}>
      <span className="presence-dot" aria-hidden="true" />
      {s}
    </span>
  );
}
