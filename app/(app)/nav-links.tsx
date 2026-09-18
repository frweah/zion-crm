"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navPath, type NavGroup, type NavItem } from "@/lib/roles";

/**
 * The sidebar: the eight groups, and nothing under them.
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
 */
export function NavLinks({
  groups,
}: {
  groups: { group: NavGroup; items: NavItem[] }[];
}) {
  const pathname = usePathname();

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
          >
            {group.label}
          </Link>
        );
      })}
    </>
  );
}
