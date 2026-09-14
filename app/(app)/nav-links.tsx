"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { currentItemHref, navPath, type NavGroup, type NavItem } from "@/lib/roles";

/**
 * The sidebar, in groups.
 *
 * The group holding the current screen is open; the rest are headers. That is
 * the whole behaviour — no remembering what somebody last expanded, no
 * animation, nothing that moves while being read. A person on Invoices sees
 * the other billing screens next to it and nothing about Contractors.
 *
 * The open group's screens sit indented under a hairline guide at full text
 * contrast. They were once lighter than the headings, and people could not
 * see them; they are never dimmed now.
 *
 * Which one is current comes from currentItemHref, the same rule the tab strip
 * uses, so the two always agree.
 *
 * A collapsed group is a link to its first item, so the header is never a
 * thing that only decorates.
 */
export function NavLinks({
  groups,
}: {
  groups: { group: NavGroup; items: NavItem[] }[];
}) {
  const pathname = usePathname();
  const tab = useSearchParams().get("tab");

  const inGroup = (items: NavItem[]) =>
    items.some((item) => {
      const path = navPath(item.href);
      return pathname === path || pathname.startsWith(path + "/");
    });

  return (
    <>
      {groups.map(({ group, items }) => {
        const open = inGroup(items);
        // A group of one is a link, not a group: "Tasks" with "Tasks" under it
        // is a heading arguing with itself.
        const single = items.length === 1;

        if (single) {
          return (
            <Link
              key={group.key}
              href={items[0].href}
              className={"navb" + (open ? " on" : "")}
              aria-current={open ? "page" : undefined}
            >
              {group.label}
            </Link>
          );
        }

        const current = open ? currentItemHref(items, pathname, tab) : null;

        return (
          <div key={group.key}>
            <Link href={items[0].href} className={"navb group" + (open ? " open" : "")}>
              <span>{group.label}</span>
              <span className="chev" aria-hidden="true">
                ›
              </span>
            </Link>

            {open && (
              <div className="navsub">
                {items.map((item) => {
                  const here = item.href === current;
                  return (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={"navb sub" + (here ? " on" : "")}
                      aria-current={here ? "page" : undefined}
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
