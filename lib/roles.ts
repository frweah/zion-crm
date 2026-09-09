/** Roles and navigation, ported from the prototype's ROLES / ROLE_LABEL. */

export const ROLE_NAMES = ["Admin", "Job Search", "Reports", "Billing"] as const;
export type Role = (typeof ROLE_NAMES)[number];

export const ROLE_LABEL: Record<Role, string> = {
  Admin: "Admin (owner)",
  "Job Search": "Job Search",
  Reports: "Intake & Reports",
  Billing: "Billing",
};

export type NavItem = { label: string; href: string };

const NAV: Record<string, NavItem> = {
  Dashboard: { label: "Dashboard", href: "/dashboard" },
  Needs: { label: "Needs attention", href: "/needs" },
  Clients: { label: "Clients", href: "/clients" },
  Leads: { label: "Job leads", href: "/leads" },
  Hours: { label: "Hours", href: "/hours" },
  Paperwork: { label: "Paperwork", href: "/paperwork" },
  Tasks: { label: "Tasks", href: "/tasks" },
  Forms: { label: "Forms", href: "/forms" },
  Counselors: { label: "Counselors", href: "/counselors" },
  Billing: { label: "Billing", href: "/billing" },
  Revenue: { label: "Revenue", href: "/revenue" },
  Referrals: { label: "Referrals", href: "/referrals" },
  Outcomes: { label: "Outcomes", href: "/outcomes" },
  Reports: { label: "Reports", href: "/reports" },
  SOPs: { label: "SOPs", href: "/sops" },
  Contractors: { label: "Contractors", href: "/contractors" },
  Staff: { label: "Staff", href: "/staff" },
};

/**
 * Which screens each role sees. Matches ROLES in the prototype, plus Job leads
 * and Hours. Everyone can see the leads board but only Admin and Job Search can
 * change it, and Hours shows each person their own — both enforced by the
 * database rather than by the navigation.
 */
export const ROLE_NAV: Record<Role, NavItem[]> = {
  Admin: ["Dashboard", "Needs", "Clients", "Referrals", "Leads", "Tasks", "Forms", "Counselors", "Billing", "Revenue", "Reports", "Outcomes", "Hours", "Paperwork", "SOPs", "Contractors", "Staff"].map(
    (k) => NAV[k],
  ),
  "Job Search": ["Dashboard", "Needs", "Clients", "Referrals", "Leads", "Tasks", "Forms", "Counselors", "Hours", "Paperwork", "SOPs"].map((k) => NAV[k]),
  Reports: ["Dashboard", "Needs", "Clients", "Referrals", "Leads", "Tasks", "Forms", "Reports", "Outcomes", "Hours", "Paperwork", "SOPs"].map((k) => NAV[k]),
  Billing: ["Dashboard", "Needs", "Clients", "Leads", "Forms", "Counselors", "Billing", "Revenue", "Hours", "Paperwork", "SOPs"].map((k) => NAV[k]),
};

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

export function canReach(role: Role, pathname: string): boolean {
  return ROLE_NAV[role].some(
    (item) => pathname === item.href || pathname.startsWith(item.href + "/"),
  );
}
