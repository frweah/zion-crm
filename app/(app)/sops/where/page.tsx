import Link from "next/link";
import { requireStaff } from "@/lib/session";
import type { Role } from "@/lib/roles";

/**
 * Where do I…?
 *
 * Half the improvements asked for after the first week described things the
 * CRM already did. This is the shortest possible answer to that: the twenty
 * things people actually ask for, and a link straight to each.
 *
 * Every entry points at something that exists today. An aspirational list
 * would be worse than none — somebody following it once and finding nothing
 * will not follow it again.
 */
type Entry = {
  ask: string;
  where: string;
  href: string;
  roles?: Role[];
};

const ENTRIES: { group: string; items: Entry[] }[] = [
  {
    group: "A client",
    items: [
      {
        ask: "See everything that has happened to a client",
        where: "Their record opens on Activity",
        href: "/clients",
      },
      {
        ask: "Add a client, or find one",
        where: "Clients — filter, then save the filter as a view",
        href: "/clients",
      },
      {
        ask: "Write a note about a visit or a call",
        where: "The client's Notes tab",
        href: "/clients",
      },
      {
        ask: "See a client's date of birth or address",
        where: "Overview — shown to Admin, Intake & Reports, or whoever they are assigned to",
        href: "/clients",
      },
      {
        ask: "Upload a signed form or a document",
        where: "The client's Files tab",
        href: "/clients",
      },
      {
        ask: "Read or send the progress report",
        where: "The client's Report tab — four reports, emailed to the counselor and logged",
        href: "/clients",
      },
      {
        ask: "See which USOR forms a client still owes",
        where: "Paperwork, under the jobs on their Overview",
        href: "/clients",
      },
      {
        ask: "Write a note or add a task without finding the client first",
        where: "The + Add button, top right of every screen",
        href: "/dashboard",
      },
    ],
  },
  {
    group: "Jobs and employers",
    items: [
      {
        ask: "Record a job a client has applied for",
        where: "Jobs we have tried, under stage history on Overview",
        href: "/clients",
      },
      {
        ask: "Be reminded about an interview",
        where: "Set the interview date on the job — the reminders appear on their own",
        href: "/clients",
      },
      {
        ask: "See every job going, across all clients",
        where: "Job leads",
        href: "/leads",
      },
      {
        ask: "Add an employer, or find their contact",
        where: "Job leads — the employer directory is on the same screen",
        href: "/leads",
      },
      {
        ask: "Turn a hire into a placement with retention checks",
        where: "Mark the job Hired, then create the placement — it is a separate step",
        href: "/leads",
      },
    ],
  },
  {
    group: "Counselors and USOR",
    items: [
      {
        ask: "See one counselor's whole caseload",
        where: "Counselors → Directory → their name",
        href: "/counselors?tab=directory",
      },
      {
        ask: "Record a call or email with a counselor",
        where: "Counselors — this is what the monthly reporting counts",
        href: "/counselors",
      },
      {
        ask: "See which reports have already gone to a counselor",
        where: "Counselors — the contact log shows what was sent and when",
        href: "/counselors",
      },
      {
        ask: "Fill in a USOR form and email it to the counselor",
        where: "The client's Forms tab",
        href: "/clients",
      },
      {
        ask: "See the blank USOR templates",
        where: "Forms",
        href: "/forms",
      },
    ],
  },
  {
    group: "My own work",
    items: [
      {
        ask: "See what needs me today",
        where: "Needs attention — the same five counters as the dashboard",
        href: "/needs",
      },
      {
        ask: "Log the hours I worked",
        where: "Hours — or start the timer and end it when you are done",
        href: "/hours",
      },
      {
        ask: "Correct hours I logged wrongly",
        where: "Hours — a correction adds a replacement with the reason, never an edit",
        href: "/hours",
      },
      {
        ask: "Submit my statement for the period",
        where: "Hours",
        href: "/hours",
      },
      {
        ask: "See what I have to do today",
        where: "Dashboard, and Tasks for the full list",
        href: "/dashboard",
      },
      {
        ask: "Sign my tax form",
        where: "Paperwork",
        href: "/paperwork",
      },
      {
        ask: "Connect my Outlook calendar and mail",
        where: "Dashboard",
        href: "/dashboard",
      },
    ],
  },
  {
    group: "Money and admin",
    items: [
      {
        ask: "See why an invoice will not send",
        where: "Billing — a required USOR form is not complete yet",
        href: "/billing",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Check authorized hours remaining",
        where: "Billing, or the client's Authorizations tab",
        href: "/billing",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Approve somebody's statement",
        where: "Hours — Approvals",
        href: "/hours?tab=approvals",
        roles: ["Admin"],
      },
      {
        ask: "Record a payment to a contractor",
        where: "Contractors",
        href: "/contractors",
        roles: ["Admin"],
      },
      {
        ask: "Set a pay rate",
        where: "Staff — rates are dated, so past work keeps the rate it was done under",
        href: "/staff",
        roles: ["Admin"],
      },
      {
        ask: "Invite somebody, or remove their access",
        where: "Staff — deactivating removes access the same moment",
        href: "/staff",
        roles: ["Admin"],
      },
      {
        ask: "Generate the 1099s",
        where: "Contractors — the threshold has to be confirmed first",
        href: "/contractors",
        roles: ["Admin"],
      },
      {
        ask: "See the numbers for the month",
        where: "Reports",
        href: "/reports",
        roles: ["Admin", "Reports", "Billing"],
      },
    ],
  },
];

export default async function WhereDoIPage() {
  const me = await requireStaff();

  const groups = ENTRIES.map((g) => ({
    ...g,
    items: g.items.filter((i) => !i.roles || i.roles.includes(me.role)),
  })).filter((g) => g.items.length > 0);

  const count = groups.reduce((n, g) => n + g.items.length, 0);

  return (
    <>
      <h1 className="h1">Where do I…?</h1>
      <p className="sub">
        The {count} things people ask for most, and where each one lives. Everything here exists
        today — <Link href="/sops">the written procedures</Link> say how to do them properly.
      </p>

      {groups.map((group) => (
        <div key={group.group} className="card" style={{ marginBottom: 14, padding: 0 }}>
          <h3 style={{ padding: "16px 16px 0" }}>{group.group}</h3>
          <table className="t">
            <tbody>
              {group.items.map((item) => (
                <tr key={item.ask}>
                  <td>
                    <Link href={item.href} style={{ fontWeight: 600 }}>
                      {item.ask}
                    </Link>
                    <div style={{ fontSize: 12, color: "var(--muted)" }}>{item.where}</div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ))}

      <p className="lock">
        Something missing, or somewhere you looked first and did not find it? That is worth saying
        — it is usually the screen that needs to be clearer, not the list that needs to be longer.
      </p>
    </>
  );
}
