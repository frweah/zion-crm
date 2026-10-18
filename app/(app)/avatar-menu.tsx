"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";
import { ThemeChoice } from "./theme-choice";
import { ReportProblem } from "./report-problem";
import type { Theme } from "./theme-actions";

/**
 * The person, top right (Design language, §1).
 *
 * Their initials, their name and role, and the things that are about them
 * rather than about the work: their own paperwork, their hours, how the
 * screen looks to them, and signing out. Those were at the bottom of the
 * sidebar, which is where the screens are - a person is not a screen.
 */
function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] ?? "") + (parts.length > 1 ? (parts[parts.length - 1][0] ?? "") : "")).toUpperCase() || "?";
}

export function AvatarMenu({
  name,
  role,
  extra,
  theme,
}: {
  name: string;
  role: string;
  extra?: string;
  theme: Theme;
}) {
  const [open, setOpen] = useState(false);
  const box = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => {
      if (box.current && !box.current.contains(e.target as Node)) setOpen(false);
    };
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    document.addEventListener("mousedown", away);
    document.addEventListener("keydown", esc);
    return () => {
      document.removeEventListener("mousedown", away);
      document.removeEventListener("keydown", esc);
    };
  }, [open]);

  return (
    <div className="avatar-menu" ref={box}>
      <button
        type="button"
        className="avatar-button"
        aria-expanded={open}
        aria-label={`${name}, ${role}`}
        onClick={() => setOpen((v) => !v)}
      >
        {initials(name)}
      </button>

      {open && (
        <div className="avatar-drop" role="menu">
          <div className="avatar-who">
            <strong>{name}</strong>
            <div className="lock">{role}</div>
            {extra && <div className="lock">{extra}</div>}
          </div>
          <Link href="/paperwork" role="menuitem" onClick={() => setOpen(false)}>
            My paperwork
          </Link>
          <Link href="/hours" role="menuitem" onClick={() => setOpen(false)}>
            My hours
          </Link>
          {/* Their own second factor (0217): set one up, or change it. */}
          <Link href="/security/two-factor" role="menuitem" onClick={() => setOpen(false)}>
            Two-step sign-in
          </Link>
          {/* Deliberately not closing the menu: a person picking a theme is
              looking at the screen change, and shutting the menu under them
              hides the thing they came to see. */}
          <ThemeChoice current={theme} />
          {/* Where somebody says the CRM is wrong, from whatever screen they
              are on (0216). Below the theme so the menu still opens on the
              two things people come to it for. */}
          <ReportProblem onDone={() => setOpen(false)} />
          <form action="/auth/signout" method="post">
            <button type="submit" role="menuitem">
              Sign out
            </button>
          </form>
        </div>
      )}
    </div>
  );
}
