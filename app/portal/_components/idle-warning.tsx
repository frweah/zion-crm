"use client";

import { useEffect, useRef, useState } from "react";
import { keepAlive } from "../actions";

const WARN_AFTER = 27 * 60_000;
const END_AFTER = 30 * 60_000;

/**
 * Three minutes' warning before the 30-minute sign-out, with one button to
 * stay. WCAG 2.2.1: a time limit is fine only if the person is told before it
 * runs out and can extend it with a simple action - and three minutes is
 * enough for somebody using a switch or a screen reader to reach the button.
 *
 * Counted from the last time this page spoke to the server, which is what the
 * database counts from. Typing on the page does not reach the server, so this
 * can warn early; it never warns late.
 */
export function IdleWarning({ previewOpen = false }: { previewOpen?: boolean }) {
  const [open, setOpen] = useState(previewOpen);
  const [minutesLeft, setMinutesLeft] = useState(3);
  const since = useRef(Date.now());
  const stay = useRef<HTMLButtonElement>(null);
  const dialog = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (previewOpen) return;
    const timer = setInterval(() => {
      const idle = Date.now() - since.current;
      if (idle >= END_AFTER) {
        window.location.assign("/portal/sign-in?ended=idle");
      } else if (idle >= WARN_AFTER) {
        setMinutesLeft(Math.max(1, Math.ceil((END_AFTER - idle) / 60_000)));
        setOpen(true);
      }
    }, 5_000);
    return () => clearInterval(timer);
  }, [previewOpen]);

  useEffect(() => {
    if (open) stay.current?.focus();
  }, [open]);

  if (!open) return null;

  const stayIn = async () => {
    await keepAlive();
    since.current = Date.now();
    setOpen(false);
  };

  // Tab stays inside the dialog while it is open; Escape means stay.
  const onKeyDown = (event: React.KeyboardEvent) => {
    if (event.key === "Escape") {
      event.preventDefault();
      void stayIn();
      return;
    }
    if (event.key !== "Tab" || !dialog.current) return;
    const stops = [...dialog.current.querySelectorAll<HTMLElement>("button")];
    const first = stops[0];
    const last = stops[stops.length - 1];
    if (event.shiftKey && document.activeElement === first) {
      event.preventDefault();
      last.focus();
    } else if (!event.shiftKey && document.activeElement === last) {
      event.preventDefault();
      first.focus();
    }
  };

  return (
    <div className="portal-scrim">
      <div
        ref={dialog}
        className="portal-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="idle-title"
        aria-describedby="idle-body"
        onKeyDown={onKeyDown}
      >
        <h2 id="idle-title">Are you still there?</h2>
        <p id="idle-body">
          To keep your information private, you will be signed out in about {minutesLeft}{" "}
          {minutesLeft === 1 ? "minute" : "minutes"} unless you choose to stay.
        </p>
        <div className="portal-actions">
          <button ref={stay} className="btn" type="button" onClick={() => void stayIn()}>
            Stay signed in
          </button>
          <form action="/portal/sign-out" method="post">
            <button className="btn ghost" type="submit">
              Sign out now
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}
