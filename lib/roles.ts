/** Roles and navigation, ported from the prototype's ROLES / ROLE_LABEL. */

export const ROLE_NAMES = [
  "Admin",
  "Job Search",
  "Reports",
  "Billing",
  "Job Coach",
  "Case Manager",
] as const;
export type Role = (typeof ROLE_NAMES)[number];

export const ROLE_LABEL: Record<Role, string> = {
  Admin: "Admin (owner)",
  "Job Search": "Job Search",
  Reports: "Intake & Client Reports",
  Billing: "Billing",
  // Both see every client and neither sees Billing's money or Admin (Intake
  // Automation Brief, 10 Oct 2026). Job Coach is Job Search plus logging
  // billable hours on a coaching authorization; Case Manager is Reports,
  // under the name that says what the person actually does.
  "Job Coach": "Job Coach",
  "Case Manager": "Case Manager",
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
export type Access = {
  role: Role;
  grants?: Grant[];
  /**
   * Whether anybody reports to this person.
   *
   * Not a role and not a grant: it is a fact about the staff list, and it
   * changes the moment somebody is given a manager. The one thing it opens is
   * the team's end of day, because a manager is sent each of their people's
   * summaries and a screen they could not open would make that pointless.
   */
  manages?: boolean;
};

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
  "Job Coach": { tasks: "edit", counselors: "edit" },
  "Case Manager": { tasks: "edit" },
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
  /** Also seen by anybody who manages somebody, whatever their role. */
  managers?: true;
  /** One line on the hub card saying what the screen is for. */
  note?: string;
};

export type NavGroup = {
  key: string;
  label: string;
  items: NavItem[];
  /** A hub opens on a page of its own feature cards (Design language, §1). */
  hub?: string;
};

/**
 * The navigation, in six groups.
 *
 * It was a flat list of nineteen links; grouping it was the first pass, the
 * consolidation (September 2026) the second, and this the third (owner,
 * 21 Sept 2026): Dashboard, Clients, Inbox, Billing, HR, Admin.
 *
 *   Dashboard  the person's day, and every task under it.
 *   Clients    the people, the jobs, and the counselors who send them.
 *   Inbox      everything that arrives: mail, texts, staff chat, the
 *              website chat, and the calendar - one unread badge.
 *   Billing    unchanged.
 *   HR         a person's own hours, paperwork, certifications and SOPs;
 *              Admin also finds the staff and contractors here.
 *   Admin      documents, system, and the Insights reports.
 *
 * The screens kept their addresses: only the grouping moved, so every link,
 * bookmark and alert still lands where it did. The group names that are new
 * addresses of their own (/inbox, /hr...) redirect to their first screen
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
    label: "Home",
    items: [
      // The person's day (owner, 21 Sept 2026). The counters open their lists
      // at /dashboard/needs.
      { label: "Today", href: "/dashboard", roles: EVERYONE, note: "What is waiting for you, in tiles." },
      // What is today, as distinct from what is waiting (Design language, §3).
      { label: "My day", href: "/my-day", roles: EVERYONE, note: "Appointments, tasks and clients, in time order." },
    ],
  },
  {
    /**
     * Clients, on the sidebar itself (owner, 15 Oct 2026).
     *
     * It was a tab inside Work, which put the practice's central record one
     * level down from a hub somebody had to know the name of. Every role
     * could already reach it - this is about how far away it is, not who may
     * open it.
     *
     * One item, so the sidebar draws it as a single button straight to the
     * list rather than a hub of cards. It is not duplicated in Work: two tab
     * strips offering the same screen is the thing §11 says to stop doing,
     * and the one that stays is the one a person can see without opening
     * anything.
     *
     * What a team member sees on it is unchanged. The role limits live on the
     * screens and in the database - the Billing tab, the money figures, the
     * Admin screens and restricted documents all follow the rules they
     * already followed, and nothing on this tab shows a dollar amount.
     */
    key: "clients",
    label: "Clients",
    items: [
      { label: "Clients", href: "/clients", roles: EVERYONE, note: "Every client the practice works with." },
    ],
  },
  {
    /**
     * My work — the client work and the person's own, in one group
     * (owner, 18 Oct 2026).
     *
     * These were two groups for a month and the line between them never held.
     * "Work" meant the caseload and "My work" meant your hours and your
     * paperwork, which reads clearly in a design note and not at all in a
     * sidebar: a job coach looking for their day had to know which of two
     * similar headings it was under, and the honest answer was often both.
     *
     * So one group, in the order somebody actually works: what is owed to
     * clients first, then what is owed about yourself.
     *
     * Jobs and Counselors were in the old Work group and are not named in the
     * owner's list. They are kept, with the client work, because dropping
     * them would take two screens out of the navigation altogether and that
     * cannot be what merging two groups was for.
     */
    key: "my-work",
    label: "My work",
    hub: "/my-work",
    items: [
      // ── the client work ──
      { label: "Tasks", href: "/tasks", roles: CASEWORK, area: "tasks", note: "Everybody's, not only your own." },
      // Where somebody with a caseload starts the day: their own clients and
      // what is due against each (Workflow brief, 20 Sept 2026).
      { label: "My clients today", href: "/my-clients", roles: ["Admin", "Job Search", "Reports"], note: "Your caseload, and what is due on each." },
      { label: "Jobs", href: "/leads", roles: EVERYONE, note: "Openings, applications and the employers behind them." },
      // The counselors who refer them; the directory, the contact log and
      // hours requests are tabs on the Counselors screen itself.
      { label: "Counselors", href: "/counselors", roles: ["Admin", "Job Search", "Billing"], area: "counselors" },
      { label: "Hours", href: "/hours", roles: EVERYONE, note: "Everything logged, and your statements." },
      // A tab of the Hours screen, so it stays with Hours. A screen whose
      // tabs are split across two sidebar groups is a screen nobody can find
      // the other half of.
      { label: "Statement approvals", href: "/hours?tab=approvals", roles: ADMIN },

      // ── and the person's own ──
      { label: "Time clock", href: "/time-clock", roles: EVERYONE, note: "Clock in and out; today and this period." },
      { label: "End of day", href: "/end-of-day", roles: EVERYONE, note: "Today's tasks, and what got in the way." },
      { label: "Paperwork", href: "/paperwork", roles: EVERYONE, note: "Your tax form, policies and signature." },
      { label: "Certifications", href: "/paperwork?tab=certifications", roles: EVERYONE },
      { label: "Knowledge base", href: "/sops", roles: EVERYONE, note: "How the practice does things, by shelf." },
      { label: "Forms and checklists", href: "/forms-and-checklists", roles: EVERYONE, note: "A visit, a worksite check, an incident." },
    ],
  },
  {
    // Everything that arrives, in one place with one unread badge (owner,
    // 21 Sept 2026). Mail is each person's own Outlook, read live; texts and
    // the website chat are one screen shown two ways.
    key: "inbox",
    label: "Communication",
    hub: "/communication",
    items: [
      { label: "Mail", href: "/mail", roles: EVERYONE, note: "Your own Outlook, read here." },
      { label: "Texts", href: "/messages/texts?tab=texts", roles: EVERYONE, note: "Clients, both ways." },
      { label: "Chat", href: "/messages", roles: EVERYONE, note: "Colleagues, and threads about a client." },
      { label: "Website chat", href: "/messages/texts?tab=web", roles: EVERYONE, note: "Whoever is on zionrehabcenter.com now." },
      { label: "Calendar", href: "/calendar", roles: EVERYONE, note: "Appointments, yours and the practice's." },
      // What the practice tells everybody, and who it can reach
      // (Design language, §3).
      { label: "Updates", href: "/updates", roles: EVERYONE, note: "Posts from the practice, and what you have read." },
      { label: "Directory", href: "/directory", roles: EVERYONE, note: "Colleagues and counselors, with their numbers." },
    ],
  },
  {
    key: "billing",
    label: "Billing",
    items: [
      // Two tabs, and the authorization is the record (Billing
      // Simplification Brief §9). Overview, Items, Invoices, Report & bill,
      // Forms and Export were six ways of looking at the same authorizations;
      // the forms, the signed authorization, the submission checklist and
      // Report & bill are on the record itself now, and the money roll-ups
      // are Admin's (§9, §13.16).
      {
        label: "Authorizations",
        href: "/billing",
        roles: BILLS,
        area: "billing",
        note: "Everything waiting to be billed, chased or paid.",
      },
      { label: "Hours", href: "/billing?tab=hours", roles: BILLS, area: "billing" },
      // The books (ERP brief, E1). Not under /insights: that is Admin's
      // alone and the people who read the books are the two already in this
      // group all day. The area is Billing's, which is also how a CPA is let
      // in - a billing grant, read-only by role and logged like everything
      // else. Posting and closing are Admin's wherever somebody comes from.
      {
        label: "Books",
        href: "/books",
        roles: BILLS,
        area: "billing",
        note: "The ledger, the bank, and the reports the year is closed with.",
      },
      // Everybody's, unlike the rest of this group: asking to buy a laptop
      // is not a billing job, and a screen only Billing can open is one the
      // person who needs it cannot reach (ERP brief, E3). Off until the
      // owner sets an amount, and the screen says so.
      { label: "Purchase requests", href: "/requests", roles: EVERYONE },
    ],
  },
  {
    // The practice's side of the same subject: the people, their paperwork
    // and their days, for whoever is accountable for them.
    key: "hr",
    label: "HR",
    hub: "/hr",
    items: [
      /**
       * Everybody's days, by person.
       *
       * Admin by role, and anybody who manages somebody by the fact that
       * they do - which is not a role and could not be written as one. A
       * manager is sent each of their people's summaries, so a screen they
       * could not open would make the notification pointless.
       */
      { label: "End of day — team", href: "/end-of-day/team", roles: ADMIN, managers: true, note: "Everybody's days, by person." },
      { label: "People", href: "/admin/people", roles: ADMIN },
      { label: "Contractors", href: "/admin/people?tab=contractors", roles: ADMIN },
    ],
  },
  {
    key: "admin",
    label: "Admin",
    // Admin's alone (owner, 19 Sept 2026), the document inbox included, and
    // the Insights reports with it (21 Sept 2026). Billing confirms the
    // authorizations from the inbox on Billing → Authorizations.
    items: [
      { label: "Documents", href: "/admin/documents", roles: ADMIN },
      // Each feature's settings on its own page (Design language, §3); what
      // stays on System is the record the system keeps about itself.
      { label: "Settings", href: "/admin/settings-hub", roles: ADMIN, note: "One page per feature." },
      { label: "System", href: "/admin/system", roles: ADMIN, note: "The access log, and what the system records about itself." },
      { label: "Money", href: "/insights/money", roles: ADMIN, area: "insights" },
      { label: "Referrals", href: "/insights/referrals", roles: ADMIN, area: "insights" },
      { label: "Outcomes", href: "/insights/outcomes", roles: ADMIN, area: "insights" },
      // No area: Capacity shows everybody's hours, so it stays Admin's even
      // for somebody given Insights.
      { label: "Capacity", href: "/insights/capacity", roles: ADMIN },
      { label: "KPIs", href: "/insights/reports", roles: ADMIN, area: "insights" },
    ],
  },
];

/** The path part of an href, with any ?tab= or #section dropped. */
export function navPath(href: string): string {
  return href.split(/[?#]/)[0];
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
  // No tab asked for: the screen that has none (Hours rather than Statement
  // approvals, Paperwork rather than Certifications), else the first tab.
  const plain = best.find((i) => !i.href.includes("?tab="));
  return (plain ?? tabbed[0] ?? best[0]).href;
}

/** What a person sees: what their role sees, and what a grant opens. Never less. */
export function visibleItems(group: NavGroup, who: Role | Access): NavItem[] {
  const a = asAccess(who);
  return group.items.filter((i) => {
    // No audience named at all means everybody, as it always has.
    if (!i.roles && !i.managers) return true;
    if (i.roles?.includes(a.role)) return true;
    if (i.area !== undefined && can(a, i.area)) return true;
    if (i.managers && a.manages) return true;
    return false;
  });
}

/** The groups this person sees, each carrying only the items they see. */
export function navFor(who: Role | Access): { group: NavGroup; items: NavItem[] }[] {
  return NAV_GROUPS.map((group) => ({ group, items: visibleItems(group, who) })).filter(
    (g) => g.items.length > 0,
  );
}

/**
 * The way back off a hub's tab: where that hub opens, or null if this screen
 * is the landing and so has nowhere above it.
 *
 * One definition, because three things need the same answer and they were
 * drifting: the arrow the layout draws, the deploy check that asserts the
 * arrow arrived, and check-nav's cases below. The first version of the deploy
 * check asked two questions that were merely near this one, and was wrong
 * about two screens on production.
 *
 * Two subtleties, both learned from those two screens. Which items a hub has
 * depends on the role, so Purchase requests - the only Billing screen a Job
 * Search person can open - is that role's Billing landing and gets no arrow,
 * since the arrow would point at a screen they cannot open. And several tabs
 * are query strings on one route, so the current tab decides and not the path:
 * /billing?tab=hours has a way back, /billing and /billing?doc=<id> do not.
 */
export function hubBack(
  groups: { group: NavGroup; items: NavItem[] }[],
  pathname: string,
  tab: string | null,
): { href: string; label: string } | null {
  // Only on a hub's own screens. A record under one of them carries its own.
  const current = groups.find(({ items }) => items.some((i) => pathname === navPath(i.href)));
  if (!current) return null;

  const landing = current.group.hub ?? current.items[0]?.href;
  if (!landing) return null;

  // A hub with a landing page of cards is never one of its own tabs. Without
  // one, the hub's first screen is the landing.
  if (!current.group.hub && currentItemHref(current.items, pathname, tab) === landing) return null;

  return { href: landing, label: current.group.label };
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
/**
 * Screens about a person's own account rather than the practice's work.
 *
 * Reachable by everybody, always, and not in the navigation: they are
 * arrived at from the avatar menu or sent to by the layout, not browsed to.
 *
 * The two-factor screen has to be on this list or it deadlocks: the layout
 * sends somebody here when the practice requires a second factor, canReach
 * refuses a path that is in no group, the layout sends them back to Home,
 * and the gate sends them here again.
 */
const ALWAYS_REACHABLE = ["/security/two-factor"];

export function canReach(who: Role | Access, pathname: string): boolean {
  if (ALWAYS_REACHABLE.some((p) => pathname === p || pathname.startsWith(p + "/"))) return true;

  const groups = navFor(who);

  /**
   * A hub's landing page of cards belongs to whoever can see what is on it.
   *
   * It is not an item, so reachableFor never carried it, and the layout gate
   * refused every hub to every role: /work, /communication and /hr all
   * redirected to Home, which is where three of the four tabs on the phone
   * bar and three sidebar headings pointed (stress test, 16 Oct 2026).
   *
   * Exactly, not by prefix: a hub is a landing page and owns no screens below
   * it. Its items carry their own paths and are matched below.
   */
  if (groups.some((g) => g.group.hub === pathname)) return true;

  const mine = groups.flatMap((g) => g.items).map((i) => navPath(i.href));
  if (mine.some((p) => p === pathname)) return true;

  /**
   * A screen that is itself in the navigation is reached on its own terms.
   *
   * The prefix below exists so a record opens through the list it is on -
   * /clients/<id> through /clients. It was never meant to hand over another
   * listed screen, and it did: /end-of-day/team is Admin's and a manager's,
   * and everybody could reach it because everybody has their own
   * /end-of-day and it sits one level above. Found by the check below
   * (18 Oct 2026).
   */
  if (NAV_GROUPS.some((g) => g.items.some((i) => navPath(i.href) === pathname))) return false;

  return mine.some((p) => pathname.startsWith(p + "/"));
}
