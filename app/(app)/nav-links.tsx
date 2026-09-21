"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navPath, type NavGroup, type NavItem } from "@/lib/roles";
import { NavIcon } from "./nav-icons";
import { useUnreadMessages } from "./live-messaging";

/**
 * The sidebar: the six groups, and nothing under them.
 *
 * Each group's screens are already the tab strip across the top of every
 * screen in it (GroupTabs), so listing them again down the side was the same
 * list twice (owner, 18 Sept 2026). The sidebar now answers one question -
 * which part of the CRM am I in - and the group holding the current screen is
 * the one highlighted.
 *
 * A group is a link to the first of its screens this person can open, so
 * somebody given Billing by a grant lands on a Billing screen, not on one
 * their access does not include.
 *
 * Each carries an icon, so the sidebar can close down to icons (below 1100px,
 * or when somebody chooses): the label is then hidden from sight but stays the
 * link's name for a screen reader, and shows as a tooltip.
 */
export function NavLinks({
  groups,
}: {
  groups: { group: NavGroup; items: NavItem[] }[];
}) {
  const pathname = usePathname();
  const unread = useUnreadMessages();

  const inGroup = (items: NavItem[]) =>
    items.some((item) => {
      const path = navPath(item.href);
      return pathname === path || pathname.startsWith(path + "/");
    });

  return (
    <>
      {groups.map(({ group, items }) => {
        const open = inGroup(items);
        return (
          <Link
            key={group.key}
            href={items[0].href}
            className={"navb" + (open ? " on" : "")}
            aria-current={open ? "true" : undefined}
            title={group.label}
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
        );
      })}
    </>
  );
}
