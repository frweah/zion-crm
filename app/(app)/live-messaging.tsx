"use client";

import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { waitingConversations } from "./inbox-count-actions";
import { mailWaiting } from "./inbox-mail";
import type { ChatSettings } from "@/lib/chat-prefs";

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
 *   A pop-up when a message arrives from somebody else: who sent it, which
 *   thread, and a way in. Not the words - a message may be about a client and
 *   the screen may be in a room with somebody who should not read it. A person
 *   who wants the words turns on "Show the message in the pop-up" on the Team
 *   page, which is off until they do (owner, 30 Oct 2026).
 *
 *   And three settings of their own, all off unless they say otherwise: the
 *   preview above, a sound, and do not disturb. Do not disturb stops the
 *   pop-up and the desktop notification and leaves the unread count, because
 *   it is about not being interrupted rather than not being told.
 *
 * The desktop notification only goes when this window is not the one in front
 * - there is no sense notifying somebody about a screen they are looking at -
 * and only if they have already allowed it. Permission is asked on the Team
 * page, by a button they press, because a browser that asks on sign-in gets
 * told no once and for all.
 *
 * Live delivery is Supabase Realtime, which sends each new message only to
 * those the database lets read it (0104).
 */

// ── the unread count, shared with the sidebar ────────────────
// One Inbox badge: the conversations waiting for this person to answer, and
// their unread mail - the same number the dashboard shows, from the same
// question (audit, 25 Sept 2026). Refreshed when a message arrives and every
// two minutes.
let waitingTotal = 0;
const listeners = new Set<() => void>();
function setWaiting(n: number) {
  waitingTotal = n;
  listeners.forEach((l) => l());
}
export function useUnreadMessages(): number {
  return useSyncExternalStore(
    (l) => {
      listeners.add(l);
      return () => listeners.delete(l);
    },
    () => waitingTotal,
    () => 0,
  );
}
const OUTSIDE_MS = 2 * 60 * 1000;

const IDLE_MS = 5 * 60 * 1000;
const BEAT_MS = 60 * 1000;

/**
 * What happens when the server stops answering.
 *
 * These two polls did not cause the outage of 14 Oct 2026, but they fed it: a
 * fixed setInterval keeps firing at the same rate whether or not anything is
 * coming back, so once the database was saturated every open tab kept adding
 * to the pile - and the catch below silently kept its last number, so nothing
 * even counted the failures. The hour saw 16,957 database calls against a
 * normal 300.
 *
 * So each poll now waits longer each time it fails - doubling, with a little
 * jitter so a roomful of tabs does not retry in lockstep - and goes back to
 * its normal rate the moment a call succeeds. A tab nobody is looking at does
 * not poll at all.
 */
const BACKOFF_CAP_MS = 10 * 60 * 1000;
const JITTER = 0.25;

/** The next wait after `failures` consecutive failures, with jitter. */
function backoff(base: number, failures: number): number {
  if (failures === 0) return base;
  const grown = Math.min(base * 2 ** failures, BACKOFF_CAP_MS);
  return Math.round(grown * (1 + (Math.random() * 2 - 1) * JITTER));
}

type Toast = { id: string; who: string; thread: string; line: string; conversationId: string };

/**
 * A short tone, built rather than fetched.
 *
 * An audio file would be one more thing to serve, cache and get wrong at
 * 3 MB; two hundred milliseconds of sine wave is the whole requirement. It is
 * created on the arrival and thrown away, because a context held open for the
 * life of the tab is a tab the browser will not let sleep.
 */
function blip(): void {
  try {
    const Ctor = window.AudioContext ?? (window as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    const ctx = new Ctor();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.frequency.value = 880;
    gain.gain.value = 0.04;
    osc.connect(gain).connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 0.18);
    osc.onended = () => void ctx.close();
  } catch {
    // A browser that will not make a sound without a gesture is not an error
    // worth saying anything about; the pop-up has already appeared.
  }
}

export function LiveMessaging({ myId, settings }: { myId: string; settings: ChatSettings }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const lastInput = useRef(Date.now());
  // Read inside the Realtime handler, which is set up once. Without the ref a
  // change of setting would not reach the handler until the page reloaded.
  const chat = useRef(settings);
  chat.current = settings;

  useEffect(() => {
    const supabase = createClient();

    // ── presence ─────────────────────────────────────────────
    const touched = () => {
      lastInput.current = Date.now();
    };
    const events = ["pointerdown", "keydown", "touchstart", "wheel"] as const;
    events.forEach((e) => window.addEventListener(e, touched, { passive: true }));
    // Self-scheduling rather than setInterval, so a failure can change when
    // the next one happens. An interval cannot: it fires on the clock whatever
    // came back, which is the behaviour that turned a slow database into a
    // rising pile of requests.
    let beatFailures = 0;
    let beatTimer = 0;
    let stopped = false;

    const beat = async () => {
      if (stopped) return;
      // Nobody is looking: say nothing and come back later. A hidden tab
      // reporting its presence every minute is pure cost.
      if (document.visibilityState === "hidden") {
        beatTimer = window.setTimeout(() => void beat(), BEAT_MS);
        return;
      }
      const state = Date.now() - lastInput.current > IDLE_MS ? "away" : "online";
      try {
        const { error } = await supabase.rpc("presence_heartbeat", { p_state: state });
        if (error) throw new Error(error.message);
        beatFailures = 0;
      } catch (err) {
        beatFailures += 1;
        if (beatFailures === 1) {
          console.warn("Presence heartbeat refused:", err instanceof Error ? err.message : err);
        }
      }
      if (!stopped) beatTimer = window.setTimeout(() => void beat(), backoff(BEAT_MS, beatFailures));
    };
    void beat();

    // ── unread and toasts ────────────────────────────────────
    // One number, worked out in one place (waitingConversations below), so
    // chat is never counted twice on its way to the badge.
    let outsideFailures = 0;
    let outsideTimer = 0;
    let inFlight = false;
    let askedAgain = false;

    const refreshOutside = async (): Promise<void> => {
      if (stopped) return;
      // One at a time, and a request that arrives while one is in flight is
      // remembered rather than sent. A burst of realtime events used to mean a
      // burst of queries; now it means one, then one more if anything changed
      // while that was running.
      if (inFlight) {
        askedAgain = true;
        return;
      }
      inFlight = true;
      try {
        // waitingConversations already counts this person's chat as well, so
        // the live half above is replaced rather than added to.
        const [waiting, mail] = await Promise.all([waitingConversations(), mailWaiting(0)]);
        setWaiting(waiting + mail.count);
        outsideFailures = 0;
      } catch (err) {
        // A badge that cannot be worked out keeps its last number - but the
        // failure is counted now, so the next attempt waits longer. Said once
        // per run of failures rather than every two minutes forever.
        outsideFailures += 1;
        if (outsideFailures === 1) {
          console.warn("The waiting count could not be read:", err instanceof Error ? err.message : err);
        }
      } finally {
        inFlight = false;
      }
      if (askedAgain && !stopped) {
        askedAgain = false;
        void refreshOutside();
      }
    };

    const pollOutside = async () => {
      if (stopped) return;
      if (document.visibilityState === "hidden") {
        outsideTimer = window.setTimeout(() => void pollOutside(), OUTSIDE_MS);
        return;
      }
      await refreshOutside();
      if (!stopped) {
        outsideTimer = window.setTimeout(() => void pollOutside(), backoff(OUTSIDE_MS, outsideFailures));
      }
    };

    const refreshUnread = () => void refreshOutside();
    void pollOutside();

    // Coming back to a tab should show the truth at once rather than up to two
    // minutes later - and this is also what makes pausing while hidden safe.
    const onVisible = () => {
      if (document.visibilityState === "visible") void refreshOutside();
    };
    document.addEventListener("visibilitychange", onVisible);
    const channel = supabase
      .channel("messages-live")
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, (payload) => {
        const row = payload.new as { id: string; conversation_id: string; sender_staff_id: string | null; sender_label: string; sender_kind: string; body?: string };
        if (row.sender_staff_id === myId) return;
        void refreshUnread();
        if (row.sender_kind !== "staff") void refreshOutside();
        window.dispatchEvent(new CustomEvent("zion:message", { detail: row }));
        // The thread is already open on this screen, so there is nothing to
        // tell anybody. Both ends of the chat count: the full page and the
        // pane that slides over whatever else they were doing.
        const open = new URLSearchParams(window.location.search).get("c");
        if (open === row.conversation_id) return;
        // Do not disturb stops the pop-up and the notification. The count has
        // already been refreshed above, which is the part it does not stop.
        if (chat.current.dnd) return;

        const who = row.sender_kind === "staff" ? row.sender_label || "A colleague" : row.sender_kind === "client" ? "A client" : "A visitor";
        // The first line, and only if they asked for it. Cut here rather than
        // in the markup so nothing downstream can render the whole message.
        const line = chat.current.preview
          ? (row.body ?? "").split("\n")[0].slice(0, 120)
          : "";

        void (async () => {
          const { data } = await supabase
            .from("conversations")
            .select("title")
            .eq("id", row.conversation_id)
            .maybeSingle();
          const thread = data?.title?.trim() || "a direct message";

          // The same message can arrive twice (a reconnect, a retry); one
          // pop-up.
          setToasts((t) =>
            t.some((x) => x.id === row.id)
              ? t
              : [...t.slice(-2), { id: row.id, who, thread, line, conversationId: row.conversation_id }],
          );
          window.setTimeout(() => setToasts((t) => t.filter((x) => x.id !== row.id)), 8000);

          if (chat.current.sound) blip();

          // Only when this window is not the one in front, and only if they
          // have already allowed it. Asking here would be asking at the worst
          // possible moment.
          if (
            document.visibilityState === "hidden" &&
            typeof Notification !== "undefined" &&
            Notification.permission === "granted"
          ) {
            try {
              new Notification(`${who} — ${thread}`, {
                body: line || "New message in Team",
                tag: row.conversation_id,
              });
            } catch {
              // Some browsers refuse this outside a service worker. The
              // pop-up is already up either way.
            }
          }
        })();
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
      // `stopped` as well as clearing the timers: a call already in flight
      // would otherwise schedule the next one after the component has gone.
      stopped = true;
      events.forEach((e) => window.removeEventListener(e, touched));
      document.removeEventListener("visibilitychange", onVisible);
      window.clearTimeout(beatTimer);
      window.clearTimeout(outsideTimer);
      void supabase.removeChannel(channel);
    };
  }, [myId]);

  return (
    <div className="toasts" aria-live="polite" aria-atomic="false">
      {toasts.map((t) => (
        <div key={t.id} className="toast" role="status">
          <span>
            <b>{t.who}</b> in {t.thread}
            {t.line && (
              <>
                <br />
                {t.line}
              </>
            )}
          </span>
          <Link
            href={`/team?c=${t.conversationId}`}
            className="btn ghost"
            style={{ padding: "2px 10px" }}
            onClick={(e) => {
              if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
              e.preventDefault();
              window.dispatchEvent(new CustomEvent("zion:open-team", { detail: t.conversationId }));
              setToasts((all) => all.filter((x) => x.id !== t.id));
            }}
          >
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
