"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { NavIcon } from "./nav-icons";

/**
 * Team, in the sidebar directly below the main tabs (owner, 30 Oct 2026).
 *
 * Its own count rather than the Inbox badge beside it. The Inbox badge is what
 * is waiting from outside the practice — a client's text, a counselor's mail —
 * and `my_unread` is what a colleague has said to this person. Two different
 * questions that were one number, and the number was the reason nobody could
 * tell whether the badge meant a client was waiting.
 *
 * Refreshed when a message arrives, because live-messaging.tsx already hears
 * every insert over Realtime and says so on the window. One subscription for
 * the whole window, not one per component.
 */
export function TeamLink() {
  const [unread, setUnread] = useState(0);
  const pathname = usePathname();
  const here = pathname === "/team";

  useEffect(() => {
    let stopped = false;
    const supabase = createClient();

    const read = async () => {
      if (stopped) return;
      const { data } = await supabase.rpc("my_unread");
      if (stopped) return;
      const rows = (data ?? []) as { unread: number }[];
      setUnread(rows.reduce((n, r) => n + (r.unread ?? 0), 0));
    };

    void read();
    const onMessage = () => void read();
    window.addEventListener("zion:message", onMessage);
    // Opening the screen reads the thread, so the count is wrong until it is
    // asked again.
    const onVisible = () => {
      if (document.visibilityState === "visible") void read();
    };
    document.addEventListener("visibilitychange", onVisible);

    return () => {
      stopped = true;
      window.removeEventListener("zion:message", onMessage);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [pathname]);

  return (
    <Link
      className={"navb" + (here ? " on" : "")}
      href="/team"
      aria-current={here ? "page" : undefined}
      onClick={(e) => {
        // A modified click is somebody asking for a new tab, and the full
        // page is the right thing to give them.
        if (e.metaKey || e.ctrlKey || e.shiftKey || e.button !== 0) return;
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("zion:open-team"));
      }}
    >
      <NavIcon name="messages" />
      <span className="side-label">Team</span>
      {unread > 0 && (
        <span className="nav-badge" aria-label={`${unread} unread`}>
          {unread > 99 ? "99+" : unread}
        </span>
      )}
    </Link>
  );
}
