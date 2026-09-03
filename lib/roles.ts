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
  Clients: { label: "Clients", href: "/clients" },
  Tasks: { label: "Tasks", href: "/tasks" },
  Forms: { label: "Forms", href: "/forms" },
  Counselors: { label: "Counselors", href: "/counselors" },
  Billing: { label: "Billing", href: "/billing" },
  Reports: { label: "Reports", href: "/reports" },
  SOPs: { label: "SOPs", href: "/sops" },
  Staff: { label: "Staff", href: "/staff" },
};

/** Which screens each role sees. Matches ROLES in the prototype. */
export const ROLE_NAV: Record<Role, NavItem[]> = {
  Admin: ["Dashboard", "Clients", "Tasks", "Forms", "Counselors", "Billing", "Reports", "SOPs", "Staff"].map(
    (k) => NAV[k],
  ),
  "Job Search": ["Dashboard", "Clients", "Tasks", "Forms", "Counselors", "SOPs"].map((k) => NAV[k]),
  Reports: ["Dashboard", "Clients", "Tasks", "Forms", "Reports", "SOPs"].map((k) => NAV[k]),
  Billing: ["Dashboard", "Clients", "Forms", "Counselors", "Billing", "SOPs"].map((k) => NAV[k]),
};

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
