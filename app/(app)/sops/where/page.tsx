import Link from "next/link";
import { requireStaff } from "@/lib/session";
import type { Role } from "@/lib/roles";
import { canReach, AREA_LABEL, LEVEL_LABEL } from "@/lib/roles";
import { PageHead } from "../../page-head";
import { DataTable } from "../../data-table";

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
        ask: "Let a client have appointment reminders by text",
        where: "Texting, on their Profile — record that they agreed first",
        href: "/clients",
      },
      {
        ask: "See who is waiting at the front and how long they have waited",
        where: "Insights → Referrals — the pipeline, with days in stage",
        href: "/insights/referrals",
        roles: ["Admin"],
      },
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
        where: "Add note, at the top of their record — pick the activity type and the headings appear",
        href: "/clients",
      },
      {
        ask: "See a client's date of birth or address",
        where: "Profile — shown to Admin, Intake & Client Reports, or whoever they are assigned to",
        href: "/clients",
      },
      {
        ask: "Upload a signed form or a document",
        where: "The client's Documents tab",
        href: "/clients",
      },
      {
        ask: "Read or send the progress report",
        where: "Send report, at the top of their record — four reports, emailed to the counselor and logged",
        href: "/clients",
      },
      {
        ask: "See which USOR forms a client still owes",
        where: "Their Billing tab — the paperwork, under their authorizations",
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
        where: "The client's Jobs tab — jobs we have tried, then placements",
        href: "/clients",
      },
      {
        ask: "Be reminded about an interview",
        where: "Set the interview date on the job — the reminders appear on their own",
        href: "/clients",
      },
      {
        ask: "See every job going, across all clients",
        where: "Clients → Jobs",
        href: "/leads",
      },
      {
        ask: "Add an employer, or find their contact",
        where: "Clients → Jobs — the employer directory is on the same screen",
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
        ask: "Give a counselor or a funder a page of outcomes",
        where: "Insights → Outcomes — pick a period and print it",
        href: "/insights/outcomes",
        roles: ["Admin"],
      },
      {
        ask: "See one counselor's whole caseload",
        where: "Counselors → Directory → their name",
        href: "/counselors?tab=directory",
      },
      {
        ask: "Record a call or email with a counselor",
        where: "Counselors → Contact log — this is what the monthly reporting counts",
        href: "/counselors",
      },
      {
        ask: "See which reports have already gone to a counselor",
        where: "Counselors → Contact log — what was sent and when",
        href: "/counselors",
      },
      {
        ask: "Fill in a USOR form and email it to the counselor",
        where: "The client's Documents tab — start the form, then email it from the form",
        href: "/clients",
      },
      {
        ask: "See the blank USOR templates",
        where: "Billing → Forms",
        href: "/billing/forms",
      },
    ],
  },
  {
    group: "My own work",
    items: [
      {
        ask: "Claim mileage or something I paid for",
        where: "Hours — claimed with the period and paid with it",
        href: "/hours",
      },
      {
        ask: "Send in a copy of my licence, insurance or a certificate",
        where: "Paperwork — add it to your own documents",
        href: "/paperwork",
      },
      {
        ask: "Log training I have done, or check when my CPR card runs out",
        where: "Paperwork — your certifications are under your tax form",
        href: "/paperwork",
      },
      {
        ask: "Decide who the next referral should go to",
        where: "Insights → Capacity — caseload, work owed, hours delivered",
        href: "/insights/capacity",
        roles: ["Admin"],
      },
      {
        ask: "See where my hours went",
        where: "Hours — the split by kind of time, for the period",
        href: "/hours",
      },
      {
        ask: "See what needs me today",
        where: "Dashboard — each counter opens its list",
        href: "/dashboard/needs",
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
        ask: "See whose certifications are about to run out",
        where: "Admin → People — every credential, with what is missing or expiring",
        href: "/admin/people",
        roles: ["Admin"],
      },
      {
        ask: "Find out who has looked at a client's file",
        where: "Admin → System → Access log — filterable by client and by person",
        href: "/admin/system#access-log",
        roles: ["Admin"],
      },
      {
        ask: "Find out how long we keep a client's file",
        where: "Admin → Documents → Retention — the schedule, and what each period is based on",
        href: "/admin/documents#retention",
        roles: ["Admin"],
      },
      {
        ask: "Stop a record being destroyed while something is going on",
        where: "Admin → Documents → Retention — place a legal hold; it outranks the schedule",
        href: "/admin/documents#retention",
        roles: ["Admin"],
      },
      {
        ask: "Give a client, or their attorney, everything we hold on them",
        where: "Admin → Documents → Records requests — gathered into one document to review, then print",
        href: "/admin/documents#records-requests",
        roles: ["Admin"],
      },
      {
        ask: "Change the legal name or EIN on our tax forms",
        where: "Admin → System — the entity, kept apart from the dba",
        href: "/admin/system",
        roles: ["Admin"],
      },
      {
        ask: "Change what a case note starts with",
        where: "Admin → System → Note headings — one set per activity type, edit or switch off",
        href: "/admin/system#note-headings",
        roles: ["Admin"],
      },
      {
        ask: "See what is authorized, earned and still owed to us",
        where: "Insights → Money",
        href: "/insights/money",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Add an authorization from the PDF USOR sent",
        where: "Billing → Authorizations → Read an authorization",
        href: "/billing/import",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Attach an authorization's PDF, or fill in its dates from it",
        where: "The client's Billing tab — attach a PDF on file; blank dates fill from it",
        href: "/clients",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Find something USOR sent that is in the documents folder",
        where: "Admin → Documents — read, sorted, and waiting for somebody to confirm. Billing confirms authorizations on Billing → Authorizations",
        href: "/admin/documents",
      },
      {
        ask: "Say whose folder a document came out of",
        where: "Admin → Documents — the folders nobody has claimed are at the top",
        href: "/admin/documents",
      },
      {
        ask: "Check the documents agent is still running",
        where: "Billing → Authorizations — it says when it last ran and what it found",
        href: "/billing?tab=authorizations#agent",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Send the accountant the month",
        where: "Billing → Export",
        href: "/billing/export",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "See why an invoice will not send",
        where: "Billing — a required USOR form is not complete yet",
        href: "/billing",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Check authorized hours remaining",
        where: "Billing, or the client's Billing tab",
        href: "/billing",
        roles: ["Admin", "Billing"],
      },
      {
        ask: "Approve somebody's statement",
        where: "My work → Statement approvals",
        href: "/hours?tab=approvals",
        roles: ["Admin"],
      },
      {
        ask: "Record a payment to a contractor",
        where: "Admin → People → Contractors",
        href: "/admin/people#contractors",
        roles: ["Admin"],
      },
      {
        ask: "Set a pay rate",
        where: "Admin → People — rates are dated, so past work keeps the rate it was done under",
        href: "/admin/people",
        roles: ["Admin"],
      },
      {
        ask: "Invite somebody, or remove their access",
        where: "Admin → People — deactivating removes access the same moment",
        href: "/admin/people",
        roles: ["Admin"],
      },
      {
        ask: "Generate the 1099s",
        where: "Admin → People → Contractors — the threshold has to be confirmed first",
        href: "/admin/people#contractors",
        roles: ["Admin"],
      },
      {
        ask: "See the numbers for the month",
        where: "Insights → KPIs",
        href: "/insights/reports",
        roles: ["Admin"],
      },
    ],
  },
];

export default async function WhereDoIPage() {
  const me = await requireStaff();

  const groups = ENTRIES.map((g) => ({
    ...g,
    // Their role's entries, and any a grant has opened: the same test the
    // sidebar and the address bar use, so this never lists a screen they
    // cannot open.
    items: g.items.filter(
      (i) => !i.roles || i.roles.includes(me.role) || canReach(me, i.href.split(/[?#]/)[0]),
    ),
  })).filter((g) => g.items.length > 0);

  const count = groups.reduce((n, g) => n + g.items.length, 0);

  // One table rather than a card per group: somebody arrives with a word in
  // mind, so the filter is always on and searches the question and the answer
  // together. The groups become a column, and the rows keep the order above.
  const rows = groups.flatMap((group) =>
    group.items.map((item, i) => ({
      key: `${group.group}-${i}`,
      cells: {
        group: <span style={{ whiteSpace: "nowrap" }}>{group.group}</span>,
        ask: (
          <Link href={item.href} style={{ fontWeight: 600 }}>
            {item.ask}
          </Link>
        ),
        where: item.where,
      },
      sort: { group: group.group, ask: item.ask, where: item.where },
      text: `${group.group} ${item.ask} ${item.where}`,
    })),
  );

  return (
    <>
      <PageHead
        title="Where do I…?"
        context={
          <>
            The {count} things people ask for most, and where each one lives. Everything here exists
            today — <Link href="/sops">the written procedures</Link> say how to do them properly.
            {me.grants.length > 0 &&
              ` Includes what you have been given beyond your role: ${me.grants
                .map((g) => `${AREA_LABEL[g.area]} (${LEVEL_LABEL[g.level]})`)
                .join(", ")}.`}
          </>
        }
      />

      <div className="card" style={{ padding: 0, marginBottom: 14 }}>
        <DataTable
          label="questions"
          filter
          columns={[
            { key: "group", label: "Group" },
            { key: "ask", label: "Where do I…" },
            { key: "where", label: "Where it is" },
          ]}
          rows={rows}
          empty="There is nothing listed for your role yet."
        />
      </div>

      <p className="lock">
        Something missing, or somewhere you looked first and did not find it? That is worth saying
        — it is usually the screen that needs to be clearer, not the list that needs to be longer.
      </p>
    </>
  );
}
