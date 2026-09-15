"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { currentItemHref, navPath, type NavGroup, type NavItem } from "@/lib/roles";

/**
 * The group's screens, as tabs across the top.
 *
 * The same list as the open sidebar group, in the place people look for tabs.
 * Rendered once in the layout rather than added to twenty-four pages, which
 * is also what stops it drifting out of step with the sidebar — there is one
 * list, and one rule (currentItemHref) for which item is current, and both
 * read them.
 *
 * Some of these tabs are query strings on one page and some are separate
 * screens. That distinction matters to the code and to nobody else, so it is
 * not visible here.
 */
export function GroupTabs({
  groups,
}: {
  groups: { group: NavGroup; items: NavItem[] }[];
}) {
  const pathname = usePathname();
  const tab = useSearchParams().get("tab");

  // Only on the group's own screens. A record under one of them (a client, a
  // counselor, a job opening) has its own header and tabs, and a row of group
  // tabs above those would be tabs stacked on tabs.
  const current = groups.find(({ items }) => items.some((i) => pathname === navPath(i.href)));

  // Nothing to show for a group of one.
  if (!current || current.items.length < 2) return null;

  const here = currentItemHref(current.items, pathname, tab);

  return (
    <>
      <div className="label tabs-label">{current.group.label}</div>
      <nav className="tabs" aria-label={current.group.label}>
        {current.items.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className={item.href === here ? "on" : ""}
            aria-current={item.href === here ? "page" : undefined}
          >
            {item.label}
          </Link>
        ))}
      </nav>
    </>
  );
}
