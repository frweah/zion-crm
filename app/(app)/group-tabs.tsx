"use client";

import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { navPath, type NavGroup, type NavItem } from "@/lib/roles";

/**
 * The group's screens, as tabs across the top.
 *
 * The same list as the open sidebar group, in the place people look for tabs.
 * Rendered once in the layout rather than added to twenty-four pages, which
 * is also what stops it drifting out of step with the sidebar — there is one
 * list and both read it.
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
  const params = useSearchParams();

  const current = groups.find(({ items }) =>
    items.some((i) => {
      const path = navPath(i.href);
      return pathname === path || pathname.startsWith(path + "/");
    }),
  );

  // Nothing to show for a group of one, and nothing on a record inside a
  // group — a client's own screen has its own tabs and does not need the
  // section's as well.
  if (!current || current.items.length < 2) return null;

  const tab = params.get("tab");

  const isHere = (item: NavItem) => {
    const path = navPath(item.href);
    if (pathname !== path && !pathname.startsWith(path + "/")) return false;

    const wanted = item.href.includes("?tab=") ? item.href.split("?tab=")[1] : null;
    if (!wanted) {
      // A plain screen is current unless a sibling tab on the same path is.
      const siblings = current.items.filter(
        (i) => navPath(i.href) === path && i.href.includes("?tab="),
      );
      return siblings.length === 0 || !tab;
    }
    // The page's own default matters: /billing with no tab is Authorizations.
    if (!tab) {
      const first = current.items.find(
        (i) => navPath(i.href) === path && i.href.includes("?tab="),
      );
      return first?.href === item.href;
    }
    return wanted === tab;
  };

  return (
    <nav className="tabs" style={{ marginBottom: 14, flexWrap: "wrap" }}>
      {current.items.map((item) => (
        <Link key={item.href} href={item.href} className={isHere(item) ? "on" : ""}>
          {item.label}
        </Link>
      ))}
    </nav>
  );
}
