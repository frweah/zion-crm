"use client";

import Link from "next/link";
import { useEffect, useRef, useState } from "react";

/**
 * The person, top right (Design language, §1).
 *
 * Their initials, their name and role, and the three things that are about
 * them rather than about the work: their own paperwork, how the screen is set
 * up for them, and signing out. Those were at the bottom of the sidebar,
 * which is where the screens are - a person is not a screen.
 */
function initials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return ((parts[0]?.[0] ?? "") + (parts.length > 1 ? (parts[parts.length - 1][0] ?? "") : "")).toUpperCase() || "?";
}

export function AvatarMenu({ name, role, extra }: { name: string; role: string; extra?: string }) {
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
