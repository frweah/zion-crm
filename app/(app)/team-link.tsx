"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NavIcon } from "./nav-icons";
import { useTeamUnread } from "./live-messaging";

/**
 * Team, in the sidebar directly below the main tabs (owner, 30 Oct 2026).
 *
 * Its own count rather than the Inbox badge beside it. The Inbox badge is what
 * is waiting from outside the practice — a client's text, a counselor's mail —
 * and `my_unread` is what a colleague has said to this person. Two different
 * questions that were one number, and the number was the reason nobody could
 * tell whether the badge meant a client was waiting.
 *
 * The number comes from live-messaging.tsx, which already hears every insert
 * and every read receipt over Realtime. One subscription and one answer for
 * the whole window: this link and the bubble bottom-left show the same count
 * because they read the same store, rather than each asking the database and
 * disagreeing by a message.
 *
 * It asked for itself until 5 Nov 2026, and the cost was not only the second
 * call - it was refreshed on an arriving message and on coming back to the
 * tab, but not on a read receipt, so reading a thread in the pane left the
 * badge showing messages that had just been read.
 */
export function TeamLink() {
  const unread = useTeamUnread();
  const pathname = usePathname();
  const here = pathname === "/team";

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
