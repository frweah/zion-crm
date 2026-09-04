import Link from "next/link";
import { requireStaff } from "@/lib/session";
import { createClient } from "@/lib/supabase/server";
import { today } from "@/lib/constants";
import {
  LogContactForm,
  AddCounselorForm,
  RequestHoursForm,
  HoursRequestRowForm,
  type HoursRequestRow,
} from "./counselors-view";

const TABS = [
  { key: "contact", label: "Contact log" },
  { key: "hours", label: "Hours requests" },
  { key: "directory", label: "Directory" },
];

export default async function CounselorsPage({
  searchParams,
}: {
  searchParams: Promise<{ tab?: string }>;
}) {
  const me = await requireStaff();
  const { tab: rawTab } = await searchParams;
  const tab = TABS.some((t) => t.key === rawTab) ? rawTab! : "contact";

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
    <>
      <h1 className="h1">Counselors</h1>
      <p className="sub">
        Counselor directory, every contact with them, and additional-hours requests
      </p>
      <nav className="tabs">
        {TABS.map((t) => (
          <Link key={t.key} href={`/counselors?tab=${t.key}`} className={t.key === tab ? "on" : ""}>
            {t.label}
          </Link>
        ))}
      </nav>
    </>
  );

  if (tab === "directory") {
    return (
      <>
        {header}
        <div
          className="grid"
          style={{
            gridTemplateColumns: "repeat(auto-fit, minmax(260px, 1fr))",
            marginBottom: 14,
          }}
        >
          {counselors.map((k) => {
            const theirs = clients.filter((c) => c.counselor_id === k.id);
            const active = theirs.filter((c) => c.status === "Active").length;
            return (
              <div key={k.id} className="card">
                <b>{k.name}</b>
                <div style={{ fontSize: 13, color: "var(--muted)" }}>{k.agency}</div>
                <div style={{ fontSize: 13, marginTop: 6 }}>
                  {k.phone && <div>Phone {k.phone}</div>}
                  {k.fax && <div>Fax {k.fax}</div>}
                  {k.email && <div>{k.email}</div>}
                  {k.office && <div>{k.office}</div>}
                  {k.notes && <div style={{ color: "var(--muted)" }}>{k.notes}</div>}
                </div>
                <div style={{ fontSize: 12, marginTop: 8 }}>
                  Active clients: {active} · total {theirs.length}
                </div>
              </div>
            );
          })}
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
          <table className="t">
            <thead>
              <tr>
                <th>Requested</th>
                <th>Authorization</th>
                <th>Client</th>
                <th>Hours</th>
                <th>Reason</th>
                <th>Counselor</th>
                <th colSpan={2}>Response</th>
              </tr>
            </thead>
            <tbody>
              {requests.length === 0 && (
                <tr>
                  <td colSpan={8} className="empty">
                    No requests yet.
                  </td>
                </tr>
              )}
              {requests.map((r) => (
                <HoursRequestRowForm key={r.id} request={r} />
              ))}
            </tbody>
          </table>
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
        <table className="t">
          <thead>
            <tr>
              <th>Date</th>
              <th>Counselor</th>
              <th>Client</th>
              <th>Method</th>
              <th>Topic</th>
              <th>Outcome</th>
              <th>Follow-up</th>
              <th>By</th>
            </tr>
          </thead>
          <tbody>
            {(contacts ?? []).length === 0 && (
              <tr>
                <td colSpan={8} className="empty">
                  No contacts logged.
                </td>
              </tr>
            )}
            {(contacts ?? []).map((x) => (
              <tr key={x.id}>
                <td>{x.date}</td>
                <td>{x.counselor_id ? (counselorName.get(x.counselor_id) ?? "—") : "—"}</td>
                <td>
                  {x.client_id ? (
                    <Link href={`/clients/${x.client_id}`} style={{ color: "var(--teal)" }}>
                      {clientName.get(x.client_id) ?? "—"}
                    </Link>
                  ) : (
                    "—"
                  )}
                </td>
                <td>
                  <span className="chip">{x.method}</span>
                </td>
                <td>{x.topic}</td>
                <td>{x.outcome}</td>
                <td>
                  {x.follow_up ? (
                    <span className={"chip " + (x.follow_up <= today() ? "warn" : "")}>
                      {x.follow_up}
                    </span>
                  ) : (
                    "—"
                  )}
                </td>
                <td>{x.staff_id ? (staffName.get(x.staff_id) ?? "—").split(" ")[0] : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
