"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { notificationFeed, dismissFromBell, type FeedItem } from "./notification-feed";
import { markConversationRead } from "./dashboard/day-actions";
import { fmtStamp } from "@/lib/constants";

/**
 * The bell: everything waiting for this person, wherever they are (Design
 * language, §1).
 *
 * It is in the header on every screen because the alternative - go to the
 * dashboard to find out whether anything happened - is a trip people stop
 * making by the second week, and then a client's text waits a fortnight.
 *
 * The list is fetched when it is opened rather than held open: a dropdown
 * that polls is a dropdown that costs something on every screen all day. The
 * count beside the bell comes from the same place the Inbox badge does, so
 * the two cannot disagree.
 */
export function Bell({ waiting }: { waiting: number }) {
  const [open, setOpen] = useState(false);
  const [items, setItems] = useState<FeedItem[] | null>(null);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    let cancelled = false;
    void notificationFeed().then((list) => {
      if (!cancelled) setItems(list);
    });
    const away = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", esc);
    return () => {
      cancelled = true;
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  const drop = (key: string) => setItems((list) => (list ?? []).filter((i) => i.key !== key));

  return (
    <div className="bell" ref={box}>
      <button
        type="button"
        className="bell-button"
        aria-expanded={open}
        aria-label={waiting > 0 ? `${waiting} waiting for you` : "Nothing waiting"}
        onClick={() => setOpen((v) => !v)}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path
            d="M18 8a6 6 0 1 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9Z"
            stroke="currentColor"
            strokeWidth="1.6"
            strokeLinejoin="round"
          />
          <path d="M10.5 21a2 2 0 0 0 3 0" stroke="currentColor" strokeWidth="1.6" strokeLinecap="round" />
        </svg>
        {waiting > 0 && <span className="bell-count">{waiting > 99 ? "99+" : waiting}</span>}
      </button>

      {open && (
        <div className="bell-drop" role="dialog" aria-label="What is waiting for you">
          <div className="bell-head">
            <strong>Waiting for you</strong>
            <Link href="/dashboard" onClick={() => setOpen(false)}>
              Your day
            </Link>
          </div>

          {items === null ? (
            <p className="lock bell-empty">Looking…</p>
          ) : items.length === 0 ? (
            <p className="empty bell-empty">Nothing is waiting for you.</p>
          ) : (
            <ul className="bell-list">
              {items.map((i) => (
                <li key={i.key}>
                  <span className={"chip" + (i.bad ? " warn" : "")}>{i.kind}</span>
                  <Link className="bell-main" href={i.href} onClick={() => setOpen(false)}>
                    <b>{i.text}</b>
                    <span className="lock"> {i.detail}</span>
                  </Link>
                  <span className="lock bell-when">{fmtStamp(i.at)}</span>
                  {i.read && (
                    <form
                      action={async (formData) => {
                        await markConversationRead(formData);
                        drop(i.key);
                      }}
                    >
                      <input type="hidden" name="conversation_id" value={i.read.conversationId} />
                      <input type="hidden" name="seq" value={i.read.seq} />
                      <button className="row-link" type="submit">
                        Mark read
                      </button>
                    </form>
                  )}
                  {i.snooze && (
                    <form
                      action={async (formData) => {
                        await dismissFromBell(formData);
                        drop(i.key);
                      }}
                    >
                      <input type="hidden" name="notification_id" value={i.snooze} />
                      <button className="row-link" type="submit">
                        Not today
                      </button>
                    </form>
                  )}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}
