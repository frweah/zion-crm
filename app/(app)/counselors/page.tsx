import Link from "next/link";
import { authorizationNumberLabel } from "@/lib/billing";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import { can, ROLE_LABEL, type Role } from "@/lib/roles";
import { startDirect } from "../messages/actions";
import { readBillingOffices, readBoParam, matchesBo } from "@/lib/billing-offices";
import { BillingOfficeFilter, withBo } from "../billing-office-filter";
import { BillingOfficesPanel } from "./billing-offices-panel";
import { DirectoryHistory, DIRECTORY_CHANGE_COLUMNS, type DirectoryChange } from "./directory-history";
import { LIVE_STATUSES } from "@/lib/billing";
import {
  LogContactForm,
  AddCounselorForm,
  RequestHoursForm,
  HoursRequestResponse,
  type HoursRequestRow,
} from "./counselors-view";

/**
 * The labels and order live with the navigation; this picks a view. The first
 * one a person can see is their default, so plain /counselors opens the tab
 * the sidebar marks current.
 *
 * The screen is everybody's since 6 November 2026, because Colleagues lives
 * here and that is the one place a person who is not Admin can look up a
 * colleague's number. The counselors themselves, the contact log and the
 * hours requests are not everybody's and did not become so: they need the
 * Counselors area, which is what each role had before. The billing offices
 * need Billing.
 */
const TABS = ["directory", "contact", "hours", "colleagues"] as const;
type Tab = (typeof TABS)[number];

export default async function CounselorsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string; bo?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab, bo: rawBo } = await searchParams;

  const supabase = await createClient();
  // Their role's, or a Counselors edit grant's. View-only grants see, not change.
  const canEdit = can(me, "counselors", "edit");
  // What each tab needs. Colleagues needs nothing beyond being staff.
  const canSee = (t: Tab) => (t === "colleagues" ? true : can(me, "counselors"));
  const mine = TABS.filter(canSee);
  const tab: Tab = mine.includes((rawTab ?? "") as Tab) ? ((rawTab as Tab) ?? mine[0]) : mine[0];
  const canSeeBilling = can(me, "billing");

  const [counselorsResult, clientsResult] = await Promise.all([
    supabase.from("counselors").select("id, name, agency, office, phone, fax, email, notes").order("name"),
    supabase.from("clients").select("id, name, counselor_id, status").order("name"),
  ]);

  const counselors = counselorsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const counselorName = new Map(counselors.map((k) => [k.id, k.name]));
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

  // Counselors is one tab of Clients now (21 Sept 2026), so its own three
  // views are chosen here rather than from the tab strip above.
  const header = (
    <>
      <PageHead
        title="Counselors"
        context={
          can(me, "counselors")
            ? "Counselors, every contact with them, hours requests, and colleagues"
            : "Colleagues, with their numbers"
        }
      />
      <div className="segmented" role="group" aria-label="Counselors" style={{ marginBottom: 14 }}>
        {(
          [
            ["directory", "Directory"],
            ["contact", "Contact log"],
            ["hours", "Hours requests"],
            ["colleagues", "Colleagues"],
          ] as const
        )
          .filter(([key]) => canSee(key))
          .map(([key, label]) => (
          <Link key={key} href={`/counselors?tab=${key}`} className={tab === key ? "on" : undefined} aria-current={tab === key ? "page" : undefined}>
            {label}
          </Link>
        ))}
      </div>
    </>
  );

  if (tab === "directory") {
    const [billing, { data: recent }] = await Promise.all([
      readBillingOffices(supabase),
      supabase.from("directory_changes").select(DIRECTORY_CHANGE_COLUMNS).order("seq", { ascending: false }).limit(25),
    ]);
    const bo = readBoParam(rawBo, billing.billingOffices);
    const billingOf = (office: string | null) => (office ? (billing.officeBilling.get(office) ?? null) : null);
    const shown = counselors.filter((k) => matchesBo(bo, billingOf(k.office)));
    // Admin, the Billing role, or a Billing edit grant (0099).
    const canEditBilling = can(me, "billing", "edit");

    // Per billing office: the offices it covers and how many counselors work from them.
    const officesOf = (id: string) => billing.offices.filter((o) => o.billing_office_id === id);
    const counselorsOf = (id: string) => counselors.filter((k) => billingOf(k.office)?.id === id).length;

    // One row per counselor rather than one card each: the directory is looked
    // up, sorted and filtered, which is what a table is for. A card is a summary.
    return (
      <>
        {header}
        <BillingOfficeFilter
          billingOffices={billing.billingOffices}
          selected={bo}
          href={(b) => withBo("/counselors?tab=directory", b)}
        />
        <div className="card" style={{ padding: 0, marginBottom: 14 }}>
          <DataTable
            label="counselors"
            sortBy
            pageSize={50}
            columns={[
              { key: "name", label: "Name" },
              { key: "agency", label: "Agency" },
              { key: "phone", label: "Phone" },
              { key: "fax", label: "Fax" },
              { key: "email", label: "Email" },
              { key: "office", label: "Office" },
              { key: "billingOffice", label: "Billing office" },
              { key: "notes", label: "Notes" },
              { key: "caseload", label: "Caseload", align: "right" },
            ]}
            rows={shown.map((k) => {
              const theirs = clients.filter((c) => c.counselor_id === k.id);
              const active = theirs.filter((c) => c.status === "Active").length;
              return {
                key: k.id,
                cells: {
                  name: (
                    <>
                      <Link href={`/counselors/${k.id}`} style={{ color: "var(--teal)" }}>
                        <b>{k.name}</b>
                      </Link>
                      {canEdit && (
                        <div>
                          <Link href={`/counselors/${k.id}#details`} className="lock no-print">
                            Edit
                          </Link>
                        </div>
                      )}
                    </>
                  ),
                  agency: k.agency,
                  phone: k.phone,
                  fax: k.fax,
                  email: k.email,
                  office: k.office,
                  billingOffice: billingOf(k.office)?.name ?? <span className="lock">None</span>,
                  notes: k.notes && <span className="lock">{k.notes}</span>,
                  caseload: (
                    <Link href={`/counselors/${k.id}`} style={{ whiteSpace: "nowrap" }}>
                      {active} active · {theirs.length} total
                    </Link>
                  ),
                },
                sort: { name: k.name, office: k.office, billingOffice: billingOf(k.office)?.name ?? "", notes: k.notes, caseload: active },
              };
            })}
            empty="No counselors in the directory yet."
          />
        </div>
        {canEdit && (
          <AddCounselorForm
            offices={billing.offices.map((o) => ({
              name: o.name,
              label: `${o.name} · ${(o.billing_office_id ? billing.byId.get(o.billing_office_id)?.name : null) ?? "no billing office"}`,
            }))}
          />
        )}

        {/* Where USOR's money comes from is Billing's and Admin's, which is
            where it was before this screen was opened to everybody. */}
        {canSeeBilling && (
        <section id="billing-offices" style={{ marginTop: 28 }}>
          <h2 className="h2" style={{ marginBottom: 4 }}>
            Billing offices
          </h2>
          <p className="sub" style={{ marginBottom: 10 }}>
            Where USOR&apos;s payments come from, and who to chase.</p>
          <div className="card" style={{ padding: 0 }}>
            <DataTable
              label="billing offices"
              columns={[
                { key: "name", label: "Billing office" },
                { key: "to", label: "Billing email goes to" },
                { key: "contact", label: "Billing contact" },
                { key: "offices", label: "Counselor offices" },
                { key: "counselors", label: "Counselors", align: "right" },
              ]}
              rows={billing.billingOffices.map((b) => ({
                key: b.id,
                text: [b.name, b.billing_email, b.contact_name, b.contact_email, ...officesOf(b.id).map((o) => o.name)].join(" "),
                sort: { name: b.name, counselors: counselorsOf(b.id) },
                cells: {
                  name: (
                    <>
                      <b>{b.name}</b>
                      {b.notes && <div className="lock">{b.notes}</div>}
                    </>
                  ),
                  to: (
                    <>
                      <a href={`mailto:${b.billing_email}`}>{b.billing_email}</a>
                      {!b.has_group_address && <div className="lock">the contact&apos;s own address - no group address yet</div>}
                    </>
                  ),
                  contact: b.contact_name ? (
                    <>
                      {b.contact_name}
                      {b.contact_title && <div className="lock">{b.contact_title}</div>}
                      {b.contact_email && (
                        <div>
                          <a href={`mailto:${b.contact_email}`}>{b.contact_email}</a>
                        </div>
                      )}
                    </>
                  ) : (
                    <span className="lock">No named contact yet</span>
                  ),
                  offices: (
                    <>
                      {officesOf(b.id).map((o) => (
                        <div key={o.name}>
                          {o.name}
                          {(o.address || o.note) && <span className="lock"> · {o.address || o.note}</span>}
                        </div>
                      ))}
                    </>
                  ),
                  counselors: (
                    <a href={withBo("/counselors?tab=directory", b.id)} style={{ whiteSpace: "nowrap" }}>
                      {counselorsOf(b.id)}
                    </a>
                  ),
                },
              }))}
              empty="No billing offices are on file."
            />
          </div>
          {canEditBilling && (
            <BillingOfficesPanel
              billingOffices={billing.billingOffices}
              offices={billing.offices}
              contactsByOffice={billing.contactsByOffice}
            />
          )}
        </section>
        )}

        <section id="directory-changes" style={{ marginTop: 28 }}>
          <h2 className="h2" style={{ marginBottom: 4 }}>
            Recent changes
          </h2>
          <p className="sub" style={{ marginBottom: 10 }}>
            The last 25 changes, and what each was before.</p>
          <div className="card" style={{ padding: 0 }}>
            <DirectoryHistory
              changes={(recent ?? []) as DirectoryChange[]}
              billingNames={new Map(billing.billingOffices.map((b) => [b.id, b.name]))}
              empty="No changes recorded since the log began."
            />
          </div>
        </section>
      </>
    );
  }

  /**
   * Colleagues (owner, 6 November 2026).
   *
   * The Directory screen had two halves and only the counselors half had
   * somewhere else to be, so this is the other half: every colleague with the
   * two things anybody wants from a directory, the number and a way to start a
   * conversation. It is the only screen where a person who is not Admin can
   * look one up — Admin → People is Admin's alone, and Team chat will find a
   * colleague but not their phone.
   *
   * A table rather than the cards the old screen drew, for the reason the
   * counselors tab beside it is a table: a directory is looked up and sorted,
   * and a card is a summary of something that needs more than one line.
   */
  if (tab === "colleagues") {
    const { data: colleagues } = await supabase
      .from("staff")
      .select("id, name, role, email, phone")
      .eq("active", true)
      .eq("is_system", false)
      .order("name");

    const roleOf = (role: string) => ROLE_LABEL[role as Role] ?? role;

    return (
      <>
        {header}
        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="colleagues"
            sortBy
            columns={[
              { key: "name", label: "Name" },
              { key: "role", label: "Role" },
              { key: "phone", label: "Phone" },
              { key: "email", label: "Email" },
              { key: "message", label: "", sortable: false },
            ]}
            rows={(colleagues ?? []).map((s) => ({
              key: s.id,
              text: [s.name, roleOf(s.role), s.phone, s.email].filter(Boolean).join(" "),
              sort: { name: s.name, role: roleOf(s.role), phone: s.phone, email: s.email },
              cells: {
                name: <b>{s.name}</b>,
                role: roleOf(s.role),
                phone: s.phone ? (
                  <a href={`tel:${s.phone.replace(/[^0-9+]/g, "")}`} style={{ whiteSpace: "nowrap" }}>
                    {s.phone}
                  </a>
                ) : (
                  <span className="lock">Not on file</span>
                ),
                email: s.email ? (
                  <a href={`mailto:${s.email}`}>{s.email}</a>
                ) : (
                  <span className="lock">Not on file</span>
                ),
                /*
                 * The old screen's Message link went to /messages?to=<id>.
                 * That address has redirected to Team since 30 October and
                 * Team has never read `to`, so the link opened the screen and
                 * started nothing. This posts to the same action the Team
                 * screen's own "Message a colleague" posts to, which asks the
                 * database for the thread and lands on it.
                 */
                message:
                  s.id === me.id ? null : (
                    <form action={startDirect}>
                      <input type="hidden" name="staff_id" value={s.id} />
                      <button className="row-link" type="submit">
                        Message
                      </button>
                    </form>
                  ),
              },
            }))}
            empty="Nobody is on the staff list yet."
          />
        </div>
      </>
    );
  }

  if (tab === "hours") {
    const [requestsResult, authsResult] = await Promise.all([
      supabase
        .from("hours_requests")
        .select("id, auth_id, counselor_id, date, hours, reason, response, approved, approved_date")
        .order("date", { ascending: false }),
      supabase
        .from("authorizations")
        .select("id, number, service_type, client_id, total_hours")
        .not("total_hours", "is", null)
        .in("status", [...LIVE_STATUSES])
        .order("number"),
    ]);

    const auths = authsResult.data ?? [];
    const authById = new Map(auths.map((a) => [a.id, a]));

    // The dropdown only offers open, hourly authorizations — a request against
    // a closed or flat-fee one is not a thing the counselor can act on.
    const authOptions = auths.map((a) => ({
      id: a.id,
      name: `${authorizationNumberLabel(a)} · ${clientName.get(a.client_id) ?? "—"} · ${a.service_type}`,
    }));

    const requests: HoursRequestRow[] = (requestsResult.data ?? []).map((r) => {
      const auth = r.auth_id ? authById.get(r.auth_id) : undefined;
      return {
        id: r.id,
        date: r.date,
        hours: r.hours,
        reason: r.reason,
        response: r.response,
        approved: r.approved,
        approved_date: r.approved_date,
        auth_number: auth ? authorizationNumberLabel(auth) : "—",
        client_name: auth?.client_id ? (clientName.get(auth.client_id) ?? "—") : "—",
        counselor_name: r.counselor_id ? (counselorName.get(r.counselor_id) ?? "—") : "—",
      };
    });

    return (
      <>
        {header}
        <div className="alert">
          Request additional hours <b>before</b> the authorization runs out. Service delivered
          beyond the authorized amount without prior approval is not payable.
        </div>

        {canEdit && <RequestHoursForm counselors={counselors} authorizations={authOptions} />}

        <div className="card" style={{ padding: 0 }}>
          <DataTable
            label="requests"
            columns={[
              { key: "date", label: "Requested" },
              { key: "auth", label: "Authorization" },
              { key: "client", label: "Client" },
              { key: "hours", label: "Hours", align: "right" },
              { key: "reason", label: "Reason" },
              { key: "counselor", label: "Counselor" },
              { key: "response", label: "Response" },
            ]}
            rows={requests.map((r) => ({
              key: r.id,
              cells: {
                date: r.date,
                auth: r.auth_number,
                client: r.client_name,
                hours: r.hours,
                reason: r.reason,
                counselor: r.counselor_name,
                response: <HoursRequestResponse request={r} />,
              },
              sort: { response: r.response },
            }))}
            empty="No additional hours have been requested yet."
          />
        </div>

        <p className="lock" style={{ marginTop: 10 }}>
          An approved request needs a new authorization before anything changes.</p>
      </>
    );
  }

  const { data: contacts } = await supabase
    .from("contact_log")
    .select("id, counselor_id, client_id, date, method, topic, outcome, follow_up, staff_id")
    .order("date", { ascending: false })
    .limit(200);

  const { data: staff } = await supabase.from("staff").select("id, name");
  const staffName = new Map((staff ?? []).map((s) => [s.id, s.name]));

  return (
    <>
      {header}
      {canEdit && (
        <LogContactForm
          counselors={counselors}
          clients={clients.filter((c) => c.status === "Active")}
        />
      )}

      <div className="card" style={{ padding: 0 }}>
        <DataTable
          label="contacts"
          columns={[
            { key: "date", label: "Date" },
            { key: "counselor", label: "Counselor" },
            { key: "client", label: "Client" },
            { key: "method", label: "Method" },
            { key: "topic", label: "Topic" },
            { key: "outcome", label: "Outcome" },
            { key: "follow", label: "Follow-up" },
            { key: "by", label: "By" },
          ]}
          rows={(contacts ?? []).map((x) => {
            const counselor = x.counselor_id ? (counselorName.get(x.counselor_id) ?? "—") : null;
            const client = x.client_id ? (clientName.get(x.client_id) ?? "—") : null;
            return {
              key: x.id,
              cells: {
                date: <span style={{ whiteSpace: "nowrap" }}>{x.date}</span>,
                counselor: x.counselor_id ? (
                  <Link href={`/counselors/${x.counselor_id}`} style={{ color: "var(--teal)" }}>
                    {counselor}
                  </Link>
                ) : (
                  "—"
                ),
                client: x.client_id ? (
                  <Link href={`/clients/${x.client_id}`} style={{ color: "var(--teal)" }}>
                    {client}
                  </Link>
                ) : (
                  "—"
                ),
                method: <span className="chip">{x.method}</span>,
                topic: x.topic,
                outcome: x.outcome,
                follow: x.follow_up ? (
                  <span className={"chip " + (x.follow_up <= today() ? "warn" : "")}>
                    {x.follow_up}
                  </span>
                ) : (
                  "—"
                ),
                by: x.staff_id ? (staffName.get(x.staff_id) ?? "—").split(" ")[0] : "—",
              },
              sort: {
                date: x.date,
                counselor,
                client,
                method: x.method,
                follow: x.follow_up,
              },
            };
          })}
          empty="No contacts have been logged yet."
        />
      </div>
    </>
  );
}
