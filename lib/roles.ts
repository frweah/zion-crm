/** Roles and navigation, ported from the prototype's ROLES / ROLE_LABEL. */

export const ROLE_NAMES = ["Admin", "Job Search", "Reports", "Billing"] as const;
export type Role = (typeof ROLE_NAMES)[number];

export const ROLE_LABEL: Record<Role, string> = {
  Admin: "Admin (owner)",
  "Job Search": "Job Search",
  Reports: "Intake & Client Reports",
  Billing: "Billing",
};

/**
 * Areas Admin can give one person beyond their role (0092).
 *
 * Roles stay the default and a grant only adds. People and Admin → System are
 * deliberately not here: a grant must not be a way into staff pay or into
 * granting. Insights is given to view, and never includes Capacity, which
 * shows everybody's hours.
 */
export const AREAS = ["tasks", "counselors", "billing", "insights"] as const;
export type Area = (typeof AREAS)[number];
export type Level = "view" | "edit";
export type Grant = { area: Area; level: Level };

/** A person as the navigation and the screens see them: their role, and anything given to them. */
export type Access = { role: Role; grants?: Grant[] };

export const AREA_LABEL: Record<Area, string> = {
  tasks: "Tasks",
  counselors: "Counselors",
  billing: "Billing",
  insights: "Insights",
};

export const LEVEL_LABEL: Record<Level, string> = { view: "view only", edit: "view and edit" };

/**
 * The levels each area can be given at. Tasks is each person's own list, which
 * everybody can already change, so "view only" would promise nothing; Insights
 * is read-only by nature.
 */
export const AREA_LEVELS: Record<Area, Level[]> = {
  tasks: ["edit"],
  counselors: ["view", "edit"],
  billing: ["view", "edit"],
  insights: ["view"],
};

/**
 * What each role has with no grant at all. The database says the same in
 * public.role_has_area (0092): verify_access_grants.sql holds the database to
 * this table, and scripts/check-nav.mjs holds the navigation to it.
 */
export const ROLE_AREAS: Record<Role, Partial<Record<Area, Level>>> = {
  Admin: { tasks: "edit", counselors: "edit", billing: "edit", insights: "view" },
  "Job Search": { tasks: "edit", counselors: "edit" },
  Reports: { tasks: "edit" },
  Billing: { counselors: "edit", billing: "edit" },
};

const asAccess = (who: Role | Access): Access => (typeof who === "string" ? { role: who, grants: [] } : who);

/**
 * May this person do this here - by their role, or by a live grant. The
 * screens ask this to decide what to offer; the database asks the same
 * question (public.staff_has_area) before it does anything.
 */
export function can(who: Role | Access, area: Area, level: Level = "view"): boolean {
  const a = asAccess(who);
  const byRole = ROLE_AREAS[a.role]?.[area];
  if (byRole && (level === "view" || byRole === "edit")) return true;
  return (a.grants ?? []).some((g) => g.area === area && (level === "view" || g.level === "edit"));
}

export type NavItem = {
  label: string;
  href: string;
  /** Who sees it. Omitted means everybody. */
  roles?: Role[];
  /** The area a grant opens it in, for somebody whose role does not include it. */
  area?: Area;
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
    // Each person's own Outlook, read live (Messaging brief, M, 19 Sept 2026).
    key: "mail",
    label: "Mail",
    items: [
      { label: "Mail", href: "/mail", roles: EVERYONE },
      { label: "Calendar", href: "/calendar", roles: EVERYONE },
    ],
  },
  {
    // Conversations: staff with staff now; texts (A) and the website chat (C)
    // join it (Messaging brief, 19 Sept 2026).
    key: "messages",
    label: "Messages",
    items: [
      { label: "Messages", href: "/messages", roles: EVERYONE },
      // Texts and website chats, in the one place (Messaging brief, A and C).
      { label: "Texts & web", href: "/messages/texts", roles: EVERYONE },
    ],
  },
  {
    key: "clients",
    label: "Clients",
    items: [
      // Where somebody with a caseload starts the day: their own clients and
      // what is due against each (Workflow brief, 20 Sept 2026).
      { label: "My clients today", href: "/my-clients", roles: ["Admin", "Job Search", "Reports"] },
      { label: "Clients", href: "/clients", roles: EVERYONE },
      { label: "Jobs", href: "/leads", roles: EVERYONE },
    ],
  },
  {
    key: "tasks",
    label: "Tasks",
    items: [{ label: "Tasks", href: "/tasks", roles: CASEWORK, area: "tasks" }],
  },
  {
    key: "counselors",
    label: "Counselors",
    items: [
      { label: "Directory", href: "/counselors?tab=directory", roles: ["Admin", "Job Search", "Billing"], area: "counselors" },
      { label: "Contact log", href: "/counselors?tab=contact", roles: ["Admin", "Job Search", "Billing"], area: "counselors" },
      { label: "Hours requests", href: "/counselors?tab=hours", roles: ["Admin", "Job Search", "Billing"], area: "counselors" },
    ],
  },
  {
    key: "billing",
    label: "Billing",
    items: [
      { label: "Authorizations", href: "/billing?tab=authorizations", roles: BILLS, area: "billing" },
      { label: "Service log", href: "/billing?tab=log", roles: BILLS, area: "billing" },
      { label: "Invoices", href: "/billing?tab=invoices", roles: BILLS, area: "billing" },
      // Pick a client, pick the authorization, the form comes up filled in
      // (owner's layout, 20 Sept 2026). Everybody who bills can reach it.
      { label: "Report & bill", href: "/billing/report", roles: EVERYONE },
      { label: "Forms", href: "/billing/forms", roles: EVERYONE },
      // The month as files, and the rate schedule - from Admin → System, so
      // that Admin is Admin's alone (owner, 19 Sept 2026). The authorizations
      // that arrive in the documents folder are confirmed on Authorizations.
      { label: "Export", href: "/billing/export", roles: BILLS, area: "billing" },
    ],
  },
  {
    key: "insights",
    label: "Insights",
    // The owner's alone, in full (14 Sept 2026). Client progress reports and
    // USOR forms stay with staff on the client record and Billing → Forms.
    items: [
      { label: "Money", href: "/insights/money", roles: ADMIN, area: "insights" },
      { label: "Referrals", href: "/insights/referrals", roles: ADMIN, area: "insights" },
      { label: "Outcomes", href: "/insights/outcomes", roles: ADMIN, area: "insights" },
      // No area: Capacity shows everybody's hours, so it stays Admin's even
      // for somebody given Insights.
      { label: "Capacity", href: "/insights/capacity", roles: ADMIN },
      { label: "KPIs", href: "/insights/reports", roles: ADMIN, area: "insights" },
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
    // Admin's alone (owner, 19 Sept 2026), the document inbox included.
    // Billing confirms the authorizations from it on Billing → Authorizations,
    // with the agent's status; the monthly export and the rate schedule are
    // Billing → Export.
    items: [
      { label: "People", href: "/admin/people", roles: ADMIN },
      { label: "Documents", href: "/admin/documents", roles: ADMIN },
      { label: "System", href: "/admin/system", roles: ADMIN },
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

/** What a person sees: what their role sees, and what a grant opens. Never less. */
export function visibleItems(group: NavGroup, who: Role | Access): NavItem[] {
  const a = asAccess(who);
  return group.items.filter(
    (i) => !i.roles || i.roles.includes(a.role) || (i.area !== undefined && can(a, i.area)),
  );
}

/** The groups this person sees, each carrying only the items they see. */
export function navFor(who: Role | Access): { group: NavGroup; items: NavItem[] }[] {
  return NAV_GROUPS.map((group) => ({ group, items: visibleItems(group, who) })).filter(
    (g) => g.items.length > 0,
  );
}

/** Every item a person may open, flattened — what canReach reads. */
export function reachableFor(who: Role | Access): NavItem[] {
  return navFor(who).flatMap((g) => g.items);
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
export function canReach(who: Role | Access, pathname: string): boolean {
  return reachableFor(who).some((item) => {
    const path = navPath(item.href);
    return pathname === path || pathname.startsWith(path + "/");
  });
}
