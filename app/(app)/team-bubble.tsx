"use client";

import { usePathname } from "next/navigation";
import { useSyncExternalStore } from "react";
import { NavIcon } from "./nav-icons";
import { useTeamUnread } from "./live-messaging";
import { subscribeTeamOpen, teamOpenNow, teamOpenClosed } from "./team-open";

/**
 * The Team bubble, bottom-left on every screen (owner, 5 Nov 2026).
 *
 * The sidebar already carries Team with the same count, and on a phone the
 * sidebar is a bar of six icons at the bottom that Team is not one of. So this
 * is the one place the count is always in the corner of somebody's eye while
 * they are doing something else, and one press away from answering - which is
 * the whole of what it is for.
 *
 * It opens the compact window rather than the pane: the pane puts a shade over
 * the page, which is right for something you dismiss and wrong for something
 * you leave open beside your work. Pressed again it puts the window away, and
 * the window keeps a half-written message.
 *
 * Two places it is not:
 *
 *   Not on the full Team page, where the same conversations fill the screen.
 *   A floating button over them would open a second, smaller copy of what is
 *   already there.
 *
 *   Not for anybody who has turned it off. `chat:bubble-off` in staff_prefs,
 *   on the Team page beside the pop-up settings.
 */
export function TeamBubble({ off }: { off: boolean }) {
  const unread = useTeamUnread();
  const pathname = usePathname();
  const open = useSyncExternalStore(subscribeTeamOpen, teamOpenNow, () => teamOpenClosed);

  if (off || pathname === "/team") return null;

  const showing = open.visible && open.mode === "compact";

  return (
    <button
      type="button"
      className={"team-bubble" + (showing ? " on" : "")}
      aria-expanded={showing}
      aria-label={unread > 0 ? `Team, ${unread} unread` : "Team"}
      onClick={() => window.dispatchEvent(new CustomEvent("zion:team-bubble"))}
    >
      <NavIcon name="messages" />
      {unread > 0 && (
        <span className="team-bubble-count" aria-hidden="true">
          {unread > 99 ? "99+" : unread}
        </span>
      )}
    </button>
  );
}
