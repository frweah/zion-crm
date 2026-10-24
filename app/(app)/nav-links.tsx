"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { navPath, type NavGroup, type NavItem } from "@/lib/roles";
import { NavIcon } from "./nav-icons";
import { useUnreadMessages } from "./live-messaging";

/**
 * The sidebar: the six groups, with the open one's screens beneath it.
 *
 * It was the six groups and nothing else for a month (owner, 18 Sept 2026):
 * each group's screens are also the tab strip across the top of every screen
 * in it, so listing them down the side as well was the same list twice. The
 * owner has asked for them back (23 Oct 2026), and the thing that makes it
 * not-twice is that only one group's are shown — the one you are in, or the
 * one you just pressed. The tab strip still carries the group you are looking
 * at; the sidebar now also answers "what else is in here" without a trip.
 *
 * **One group at a time.** Pressing a group opens it and closes whichever was
 * open. There is no closing a group by pressing it again: a sidebar where
 * every group can be shut is a sidebar somebody can leave showing nothing,
 * and the group holding the screen you are on should always be showing its
 * screens.
 *
 * A group is still a link - to its hub, or to the first of its screens this
 * person can open - so pressing it both opens it and goes there, and somebody
 * given Billing by a grant lands on a Billing screen rather than on one their
 * access does not include.
 *
 * **Not in the rail.** Closed to icons (below 1100px, or by choice) there is
 * no room for a label, and a screen's name is all a sub-item has - so the
 * rail stays the six icons it was. The phone's bottom bar is untouched: it is
 * its own component and its own five destinations.
 */
export function NavLinks({
  groups,
  narrow = false,
}: {
  groups: { group: NavGroup; items: NavItem[] }[];
  narrow?: boolean;
}) {
  const pathname = usePathname();
  // The group's screens are often one route with a ?tab=, so which one is
  // showing cannot be read off the path. The layout wraps this in Suspense
  // for exactly this hook.
  const search = useSearchParams();
  const unread = useUnreadMessages();

  const inGroup = (group: NavGroup, items: NavItem[]) =>
    (group.hub ? pathname === group.hub : false) ||
    items.some((item) => {
      const path = navPath(item.href);
      return pathname === path || pathname.startsWith(path + "/");
    });

  const here = groups.find(({ group, items }) => inGroup(group, items))?.group.key ?? null;

  /**
   * The group somebody pressed, until they arrive somewhere.
   *
   * Pressing a group navigates as well as opening it, so for the moment
   * between the press and the new screen this is what keeps it open. Once the
   * path settles it is cleared and the group holding the current screen is
   * the open one again - otherwise pressing Billing and then reaching a
   * client's record from somewhere else would leave Billing open while
   * Clients was the one highlighted.
   */
  const [pressed, setPressed] = useState<string | null>(null);
  useEffect(() => setPressed(null), [pathname]);

  const openKey = pressed ?? here;

  return (
    <>
      {groups.map(({ group, items }) => {
        const current = here === group.key;
        const open = !narrow && openKey === group.key;
        return (
          <div key={group.key} className="nav-group">
            <Link
              // A hub opens on its own page of cards; a group without one goes
              // straight to its first screen (Design language, §1).
              href={group.hub ?? items[0].href}
              className={"navb" + (current ? " on" : "")}
              aria-current={current ? "true" : undefined}
              aria-expanded={narrow ? undefined : open}
              title={group.label}
              onClick={() => setPressed(group.key)}
            >
              <NavIcon name={group.key} />
              <span className="side-label">{group.label}</span>
              {group.key === "inbox" && unread > 0 && (
                <span className="nav-badge">
                  {unread > 99 ? "99+" : unread}
                  <span className="side-label"> unread</span>
                </span>
              )}
            </Link>

            {open && (
              <div className="nav-sub">
                {items.map((item) => {
                  const path = navPath(item.href);
                  const tab = item.href.includes("?") ? item.href.slice(item.href.indexOf("?")) : "";
                  // Several screens of a group are query strings on one route,
                  // so the path alone cannot say which is showing. Where the
                  // item names a tab, the address has to carry it too.
                  const wantedTab = tab ? new URLSearchParams(tab).get("tab") : null;
                  const on =
                    (pathname === path || pathname.startsWith(path + "/")) &&
                    (wantedTab === null
                      ? !search.get("tab") || items.every((o) => !o.href.includes("?"))
                      : search.get("tab") === wantedTab);
                  return (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={"nav-sub-link" + (on ? " on" : "")}
                      aria-current={on ? "page" : undefined}
                    >
                      {item.label}
                    </Link>
                  );
                })}
              </div>
            )}
          </div>
        );
      })}
    </>
  );
}
