/** Roles and navigation, ported from the prototype's ROLES / ROLE_LABEL. */

export const ROLE_NAMES = ["Admin", "Job Search", "Reports", "Billing"] as const;
export type Role = (typeof ROLE_NAMES)[number];

export const ROLE_LABEL: Record<Role, string> = {
  Admin: "Admin (owner)",
  "Job Search": "Job Search",
  Reports: "Intake & Client Reports",
  Billing: "Billing",
};

export type NavItem = {
  label: string;
  href: string;
  /** Who sees it. Omitted means everybody. */
  roles?: Role[];
};

export type NavGroup = {
  key: string;
  label: string;
  items: NavItem[];
};

/**
 * The navigation, in eight groups.
 *
 * It was a flat list of nineteen links, which is the shape a system takes when
 * screens are added one at a time and nobody stops to say what belongs with
 * what. Grouping it was the first pass; the consolidation (September 2026) was
 * the second: one home per fact, no more than six tabs to a screen, reports in
 * Insights and settings in Admin → System. Every path that moved redirects
 * (next.config.mjs), and scripts/check-nav.mjs holds each role to the screens
 * it should reach.
 *
 * Roles are declared once, on the item. A group shows if any of its items do,
 * so nothing has to be kept in step by hand.
 */
const EVERYONE = undefined;
const ADMIN: Role[] = ["Admin"];
const BILLS: Role[] = ["Admin", "Billing"];
const CASEWORK: Role[] = ["Admin", "Job Search", "Reports"];

export const NAV_GROUPS: NavGroup[] = [
  {
    key: "dashboard",
    label: "Dashboard",
    // One page. The counters open their lists at /dashboard/needs.
    items: [{ label: "Dashboard", href: "/dashboard", roles: EVERYONE }],
  },
  {
    key: "clients",
    label: "Clients",
    items: [
      { label: "Clients", href: "/clients", roles: EVERYONE },
      { label: "Jobs", href: "/leads", roles: EVERYONE },
    ],
  },
  {
    key: "tasks",
    label: "Tasks",
    items: [{ label: "Tasks", href: "/tasks", roles: CASEWORK }],
  },
  {
    key: "counselors",
    label: "Counselors",
    items: [
      { label: "Directory", href: "/counselors?tab=directory", roles: ["Admin", "Job Search", "Billing"] },
      { label: "Contact log", href: "/counselors?tab=contact", roles: ["Admin", "Job Search", "Billing"] },
      { label: "Hours requests", href: "/counselors?tab=hours", roles: ["Admin", "Job Search", "Billing"] },
    ],
  },
  {
    key: "billing",
    label: "Billing",
    items: [
      { label: "Authorizations", href: "/billing?tab=authorizations", roles: BILLS },
      { label: "Service log", href: "/billing?tab=log", roles: BILLS },
      { label: "Invoices", href: "/billing?tab=invoices", roles: BILLS },
      { label: "Forms", href: "/billing/forms", roles: EVERYONE },
    ],
  },
  {
    key: "insights",
    label: "Insights",
    // The owner's alone, in full (14 Sept 2026). Client progress reports and
    // USOR forms stay with staff on the client record and Billing → Forms.
    items: [
      { label: "Money", href: "/insights/money", roles: ADMIN },
      { label: "Referrals", href: "/insights/referrals", roles: ADMIN },
      { label: "Outcomes", href: "/insights/outcomes", roles: ADMIN },
      { label: "Capacity", href: "/insights/capacity", roles: ADMIN },
      { label: "KPIs", href: "/insights/reports", roles: ADMIN },
    ],
  },
  {
    key: "my-work",
    label: "My work",
    items: [
      { label: "Hours", href: "/hours", roles: EVERYONE },
      // Was a row of tabs inside Hours, under My work's own tabs.
      { label: "Statement approvals", href: "/hours?tab=approvals", roles: ADMIN },
      { label: "Paperwork", href: "/paperwork", roles: EVERYONE },
      { label: "SOPs", href: "/sops", roles: EVERYONE },
    ],
  },
  {
    key: "admin",
    label: "Admin",
    items: [
      { label: "People", href: "/admin/people", roles: ADMIN },
      // The document inbox is everybody's; retention and records requests on
      // the same page are Admin's, and the page shows them to Admin only.
      { label: "Documents", href: "/admin/documents", roles: EVERYONE },
      // Billing reaches System for the monthly export; the rest is Admin's.
      { label: "System", href: "/admin/system", roles: BILLS },
    ],
  },
];

/** The path part of an href, with any ?tab= dropped. */
export function navPath(href: string): string {
  return href.split("?")[0];
}

/**
 * Which item of a group is the screen being looked at - one answer, used by
 * both the sidebar and the tab strip so the two cannot disagree.
 *
 * Several screens are one path told apart by ?tab= (Billing's Authorizations,
 * Service log, Invoices...). Matching the path alone marked every one of them
 * current at once. So: the most specific path wins (/billing/forms over
 * /billing); among items on the same path, the one whose tab matches; with no
 * tab, or one nobody lists, the page's own default - its first tab.
 */
export function currentItemHref(
  items: NavItem[],
  pathname: string,
  tab: string | null,
): string | null {
  const onPath = items.filter((item) => {
    const path = navPath(item.href);
    return pathname === path || pathname.startsWith(path + "/");
  });
  if (onPath.length === 0) return null;

  const longest = Math.max(...onPath.map((i) => navPath(i.href).length));
  const best = onPath.filter((i) => navPath(i.href).length === longest);
  if (best.length === 1) return best[0].href;

  const tabbed = best.filter((i) => i.href.includes("?tab="));
  if (tab) {
    const match = tabbed.find((i) => i.href.split("?tab=")[1] === tab);
    if (match) return match.href;
  }
  return (tabbed[0] ?? best[0]).href;
}

export function visibleItems(group: NavGroup, role: Role): NavItem[] {
  return group.items.filter((i) => !i.roles || i.roles.includes(role));
}

/** The groups this role sees, each carrying only the items they see. */
export function navFor(role: Role): { group: NavGroup; items: NavItem[] }[] {
  return NAV_GROUPS.map((group) => ({ group, items: visibleItems(group, role) })).filter(
    (g) => g.items.length > 0,
  );
}

/** Every item a role may open, flattened — what canReach reads. */
export function reachableFor(role: Role): NavItem[] {
  return navFor(role).flatMap((g) => g.items);
}

/**
 * The practice as clients and USOR know it.
 *
 * This is the dba, and it belongs on everything client-facing and everything
 * that goes to USOR: forms, progress reports, invoices, email. It is not the
 * legal entity. Tax filings — the W-4 employer block, the 1099 payer — carry
 * Zion Healing Academy LLC, which lives in org_settings because it is data the
 * owner maintains rather than a constant. Do not reconcile the two.
 */
export const ORG = {
  name: "Zion Vocational Rehabilitation Center",
  address: "2880 S Main Street Ste 105, Salt Lake City, Utah 84115",
  phone: "801-657-6671", // counselor line
  clientPhone: "385-406-3432", // client line
  email: "service@zionvocrehab.com",
  web: "zionrehabcenter.com",
  vendor: "VC0000277370",
} as const;

/**
 * Whether typing a URL should get somebody further than the navigation does.
 *
 * Matched on the path alone: a tab is a query string, and refusing somebody a
 * tab they can reach by clicking would be a gate that only annoys.
 */
export function canReach(role: Role, pathname: string): boolean {
  return reachableFor(role).some((item) => {
    const path = navPath(item.href);
    return pathname === path || pathname.startsWith(path + "/");
  });
}
