"use client";

import { usePathname, useSearchParams } from "next/navigation";
import { hubBack, type NavGroup, type NavItem } from "@/lib/roles";
import { BackLink } from "./back-link";

/**
 * The way back off a hub's tab, to where the hub opens.
 *
 * A record page carries its own way back on its header, because what it goes
 * back to depends on the record. A hub's tab does not: it goes to the hub's
 * landing screen, which the navigation already knows. So this is rendered once
 * in the layout, beside the tab strip, for the same reason the tab strip is -
 * there is one list and one rule for which item is current, and adding a
 * twenty-fifth screen to a hub should not mean remembering a twenty-fifth back
 * arrow.
 *
 * Which screen shows no arrow is the hub's landing, and there are two kinds.
 * Work, Communication and HR open on a page of cards, which is not one of the
 * hub's tabs - so every tab gets an arrow and the landing is never one of
 * them. Home, Billing and Admin have no such page and open on their first
 * screen instead, so that screen is the one without an arrow. Several of those
 * tabs are query strings on a single page (Billing's Authorizations and Hours
 * are one route), which is why the tab decides this and not the path.
 */
export function HubBack({ groups }: { groups: { group: NavGroup; items: NavItem[] }[] }) {
  const pathname = usePathname();
  const tab = useSearchParams().get("tab");

  const back = hubBack(groups, pathname, tab);
  if (!back) return null;
  return <BackLink href={back.href} label={back.label} />;
}
