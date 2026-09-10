"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { navPath, type NavGroup, type NavItem } from "@/lib/roles";

/**
 * The sidebar, in groups.
 *
 * The group holding the current screen is open; the rest are headers. That is
 * the whole behaviour — no remembering what somebody last expanded, no
 * animation, nothing that moves while being read. A person on Invoices sees
 * the other billing screens next to it and nothing about Contractors.
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

  const holds = (items: NavItem[]) =>
    items.some((i) => {
      const path = navPath(i.href);
      return pathname === path || pathname.startsWith(path + "/");
    });

  return (
    <>
      {groups.map(({ group, items }) => {
        const open = holds(items);
        // A group of one is a link, not a group: "Tasks" with "Tasks" under it
        // is a heading arguing with itself.
        const single = items.length === 1;

        if (single) {
          return (
            <Link
              key={group.key}
              href={items[0].href}
              className={"navb" + (open ? " on" : "")}
            >
              {group.label}
            </Link>
          );
        }

        return (
          <div key={group.key} style={{ marginBottom: open ? 6 : 0 }}>
            <Link
              href={items[0].href}
              className={"navb" + (open ? " group-on" : "")}
              style={{ fontWeight: open ? 600 : 500 }}
            >
              {group.label}
            </Link>

            {open && (
              <div style={{ margin: "2px 0 0" }}>
                {items.map((item) => {
                  const path = navPath(item.href);
                  const here =
                    pathname === path || pathname.startsWith(path + "/");
                  return (
                    <Link
                      key={item.href}
                      href={item.href}
                      className={"navb sub" + (here ? " on" : "")}
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
