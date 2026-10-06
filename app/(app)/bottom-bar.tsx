"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { NavIcon } from "./nav-icons";
import { useUnreadMessages } from "./live-messaging";
import type { NavGroup, NavItem } from "@/lib/roles";

/**
 * The hubs as a bar across the bottom, on a phone (Design language, §1).
 *
 * A sidebar on a phone is either a drawer nobody opens or a column of icons
 * taking a fifth of a narrow screen. The bar is where a thumb already is, and
 * it holds the same hubs in the same order: Home, Work, Communication, HR,
 * and More for whatever else this person has.
 *
 * It is hidden above 760px, where the sidebar does this job.
 */
export function BottomBar({ groups }: { groups: { group: NavGroup; items: NavItem[] }[] }) {
  const pathname = usePathname();
  const unread = useUnreadMessages();

  const main = ["dashboard", "work", "inbox", "hr"];
  const shown = main
    .map((key) => groups.find((g) => g.group.key === key))
    .filter((g): g is { group: NavGroup; items: NavItem[] } => Boolean(g));
  const rest = groups.filter((g) => !main.includes(g.group.key));

  const here = (g: { group: NavGroup; items: NavItem[] }) =>
    (g.group.hub && pathname === g.group.hub) ||
    g.items.some((i) => pathname === i.href.split("?")[0] || pathname.startsWith(i.href.split("?")[0] + "/"));

  return (
    <nav className="bottom-bar no-print" aria-label="Main, on a phone">
      {shown.map((g) => (
        <Link
          key={g.group.key}
          href={g.group.hub ?? g.items[0].href}
          className={"bottom-item" + (here(g) ? " on" : "")}
          aria-current={here(g) ? "page" : undefined}
        >
          <NavIcon name={g.group.key} />
          <span>{g.group.key === "dashboard" ? "Home" : g.group.label}</span>
          {g.group.key === "inbox" && unread > 0 && <span className="bottom-badge">{unread > 99 ? "99+" : unread}</span>}
        </Link>
      ))}
      {rest.length > 0 && (
        <Link
          href={rest[0].group.hub ?? rest[0].items[0].href}
          className={"bottom-item" + (rest.some(here) ? " on" : "")}
        >
          <NavIcon name={rest[0].group.key} />
          <span>More</span>
        </Link>
      )}
    </nav>
  );
}
