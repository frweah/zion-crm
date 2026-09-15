import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import { PageHead } from "../page-head";
import { DataTable } from "../data-table";
import {
  LogContactForm,
  AddCounselorForm,
  RequestHoursForm,
  HoursRequestResponse,
  type HoursRequestRow,
} from "./counselors-view";

/**
 * The labels and order live with the navigation; this picks a view. The first
 * is the default, and it is the first in the sidebar, so plain /counselors
 * opens the tab the sidebar marks current.
 */
const TABS = ["directory", "contact", "hours"];

export default async function CounselorsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab } = await searchParams;
  const tab = TABS.includes(rawTab ?? "") ? rawTab! : TABS[0];

  const supabase = await createClient();
  const canEdit = me.role !== "Reports";

  const [counselorsResult, clientsResult] = await Promise.all([
    supabase.from("counselors").select("id, name, agency, office, phone, fax, email, notes").order("name"),
    supabase.from("clients").select("id, name, counselor_id, status").order("name"),
  ]);

  const counselors = counselorsResult.data ?? [];
  const clients = clientsResult.data ?? [];
  const counselorName = new Map(counselors.map((k) => [k.id, k.name]));
  const clientName = new Map(clients.map((c) => [c.id, c.name]));

  const header = (
    <PageHead
      title="Counselors"
      context="Counselor directory, every contact with them, and additional-hours requests"
    />
  );

  if (tab === "directory") {
    // One row per counselor rather than one card each: the directory is looked
    // up, sorted and filtered, which is what a table is for. A card is a summary.
    return (
      <>
        {header}
        <div className="card" style={{ padding: 0, marginBottom: 14 }}>
          <DataTable
            label="counselors"
            columns={[
              { key: "name", label: "Name" },
              { key: "agency", label: "Agency" },
              { key: "phone", label: "Phone" },
              { key: "fax", label: "Fax" },
              { key: "email", label: "Email" },
              { key: "office", label: "Office" },
              { key: "notes", label: "Notes" },
              { key: "caseload", label: "Caseload", align: "right" },
            ]}
            rows={counselors.map((k) => {
              const theirs = clients.filter((c) => c.counselor_id === k.id);
              const active = theirs.filter((c) => c.status === "Active").length;
              return {
                key: k.id,
                cells: {
                  name: (
                    <Link href={`/counselors/${k.id}`} style={{ color: "var(--teal)" }}>
                      <b>{k.name}</b>
                    </Link>
                  ),
                  agency: k.agency,
                  phone: k.phone,
                  fax: k.fax,
                  email: k.email,
                  office: k.office,
                  notes: k.notes && <span className="lock">{k.notes}</span>,
                  caseload: (
                    <Link href={`/counselors/${k.id}`} style={{ whiteSpace: "nowrap" }}>
                      {active} active · {theirs.length} total
                    </Link>
                  ),
                },
                sort: { name: k.name, notes: k.notes, caseload: active },
              };
            })}
            empty="No counselors in the directory yet."
          />
        </div>
        {canEdit && <AddCounselorForm />}
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
        .eq("status", "Open")
        .order("number"),
    ]);

    const auths = authsResult.data ?? [];
    const authById = new Map(auths.map((a) => [a.id, a]));

    // The dropdown only offers open, hourly authorizations — a request against
    // a closed or flat-fee one is not a thing the counselor can act on.
    const authOptions = auths.map((a) => ({
      id: a.id,
      name: `${a.number || "(no number)"} · ${clientName.get(a.client_id) ?? "—"} · ${a.service_type}`,
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
        auth_number: auth?.number ?? "—",
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
          Approved hours do not change the authorization automatically — the counselor issues a
          new or amended authorization, which Billing then adds. That keeps our record matching
          USOR&apos;s.
        </p>
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
